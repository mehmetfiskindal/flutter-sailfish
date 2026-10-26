// Qt/OpenGL ES runner that hosts the Flutter engine on Sailfish OS.
//
// Provides: rendering, touch input, platform channels (flutter/platform,
// flutter/textinput, flutter/lifecycle), on-screen keyboard through Qt's input
// method and keyboard insets. No accessibility yet.

#include <QCoreApplication>
#include <QClipboard>
#include <QDir>
#include <QSettings>
#include <QEvent>
#include <QFileInfo>
#include <QGuiApplication>
#include <QHash>
#include <QInputMethod>
#include <QInputMethodEvent>
#include <QInputMethodQueryEvent>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QScreen>
#include <QSurfaceFormat>
#include <QThread>
#include <QTouchEvent>
#include <QWindow>

#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>

#include "flutter_embedder.h"

namespace {

// Verbose diagnostics (platform messages, input events) are off unless FLUTTER_SAILFISH_VERBOSE is set.
bool Verbose() {
  static const bool v = getenv("FLUTTER_SAILFISH_VERBOSE") != nullptr;
  return v;
}
#define VLOG(...)                                \
  do {                                           \
    if (Verbose()) fprintf(stderr, __VA_ARGS__); \
  } while (0)

// A platform message received on the engine's platform thread, handed over to
// the Qt GUI thread.
class MessageEvent : public QEvent {
 public:
  static QEvent::Type type() {
    static const QEvent::Type t = static_cast<QEvent::Type>(QEvent::registerEventType());
    return t;
  }
  MessageEvent(QString channel, QByteArray data, const FlutterPlatformMessageResponseHandle* handle)
      : QEvent(type()), channel(std::move(channel)), data(std::move(data)), handle(handle) {}
  QString channel;
  QByteArray data;
  const FlutterPlatformMessageResponseHandle* handle;
};

// A task the engine wants to run on the platform thread (the Qt GUI thread) at a given time.
class TaskEvent : public QEvent {
 public:
  static QEvent::Type type() {
    static const QEvent::Type t = static_cast<QEvent::Type>(QEvent::registerEventType());
    return t;
  }
  TaskEvent(FlutterTask task, uint64_t target_nanos)
      : QEvent(type()), task(task), target_nanos(target_nanos) {}
  FlutterTask task;
  uint64_t target_nanos;
};

class Runner : public QWindow {
 public:
  Runner(QString assets, QString icu, QString aot)
      : assets_(std::move(assets)), icu_(std::move(icu)), aot_(std::move(aot)) {
    setSurfaceType(QSurface::OpenGLSurface);
    QSurfaceFormat fmt;
    fmt.setRenderableType(QSurfaceFormat::OpenGLES);
    fmt.setVersion(2, 0);
    fmt.setDepthBufferSize(0);
    fmt.setStencilBufferSize(8);
    setFormat(fmt);
    create();

    offscreen_.setFormat(fmt);
    offscreen_.create();

    // The keyboard overlaps the window; report it as a bottom view inset.
    connect(QGuiApplication::inputMethod(), &QInputMethod::keyboardRectangleChanged, this,
            [this] { SendMetrics(); });
    connect(qGuiApp, &QGuiApplication::applicationStateChanged, this,
            [this](Qt::ApplicationState state) { SendLifecycle(state); });
  }

  ~Runner() override {
    if (engine_) FlutterEngineShutdown(engine_);
  }

  // ---- Rendering (engine raster/io threads) ------------------------------

  // The context is created lazily so that it belongs to the raster thread.
  bool MakeCurrent() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!context_) {
      context_ = new QOpenGLContext;
      context_->setFormat(format());
      if (!context_->create()) {
        fprintf(stderr, "runner: creating GL context failed\n");
        return false;
      }
      cv_.notify_all();
    }
    bool ok = context_->makeCurrent(this);
    if (!logged_gl_) {
      logged_gl_ = true;
      auto* f = context_->functions();
      fprintf(stderr, "runner: makeCurrent=%d GL_VERSION=%s GL_RENDERER=%s size=%dx%d\n", ok,
              ok ? f->glGetString(GL_VERSION) : reinterpret_cast<const GLubyte*>("?"),
              ok ? f->glGetString(GL_RENDERER) : reinterpret_cast<const GLubyte*>("?"), width(),
              height());
    } else if (!ok) {
      fprintf(stderr, "runner: makeCurrent failed\n");
    }
    return ok;
  }

  bool ClearCurrent() {
    if (context_) context_->doneCurrent();
    return true;
  }

  bool Present() {
    context_->swapBuffers(this);
    if (++frames_ <= 3) fprintf(stderr, "runner: presented frame %d\n", frames_);
    return true;
  }

  bool MakeResourceCurrent() {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [this] { return context_ != nullptr; });
    if (!resource_context_) {
      resource_context_ = new QOpenGLContext;
      resource_context_->setFormat(format());
      resource_context_->setShareContext(context_);
      if (!resource_context_->create()) {
        fprintf(stderr, "runner: creating resource GL context failed\n");
        return false;
      }
    }
    return resource_context_->makeCurrent(&offscreen_);
  }

  void* ProcAddress(const char* name) {
    QOpenGLContext* ctx = QOpenGLContext::currentContext();
    return ctx ? reinterpret_cast<void*>(ctx->getProcAddress(name)) : nullptr;
  }

  // ---- Platform task runner ----------------------------------------------
  // Without a custom platform task runner the engine queues platform tasks on a
  // message loop nobody runs, so platform channel messages would never arrive.

  void PostPlatformTask(FlutterTask task, uint64_t target_nanos) {
    QCoreApplication::postEvent(this, new TaskEvent(task, target_nanos));
  }

  void ScheduleTask(const TaskEvent* t) {
    uint64_t now = FlutterEngineGetCurrentTime();
    if (t->target_nanos <= now) {
      RunTask(t->task);
    } else {
      int id = startTimer(static_cast<int>((t->target_nanos - now + 999999) / 1000000), Qt::PreciseTimer);
      timers_.insert(id, t->task);
    }
  }

  void RunTask(const FlutterTask& task) {
    if (engine_) FlutterEngineRunTask(engine_, &task);
  }

  // ---- Platform messages from the engine (platform thread) ---------------

  void OnPlatformMessage(const FlutterPlatformMessage* m) {
    VLOG("runner: engine message on %s\n", m->channel);
    QCoreApplication::postEvent(
        this, new MessageEvent(QString::fromUtf8(m->channel),
                               QByteArray(reinterpret_cast<const char*>(m->message), m->message_size),
                               m->response_handle));
  }

 protected:
  // ---- Qt events (GUI thread) --------------------------------------------

  bool event(QEvent* e) override {
    if (e->type() == TaskEvent::type()) {
      ScheduleTask(static_cast<TaskEvent*>(e));
      return true;
    }
    if (e->type() == MessageEvent::type()) {
      HandleMessage(static_cast<MessageEvent*>(e));
      return true;
    }
    switch (e->type()) {
      case QEvent::InputMethod:
        HandleInputMethod(static_cast<QInputMethodEvent*>(e));
        return true;
      case QEvent::InputMethodQuery: {
        auto* q = static_cast<QInputMethodQueryEvent*>(e);
        for (int bit = 0; bit < 32; ++bit) {
          Qt::InputMethodQuery query = static_cast<Qt::InputMethodQuery>(1u << bit);
          if (q->queries() & query) q->setValue(query, InputQuery(query));
        }
        return true;
      }
      default:
        return QWindow::event(e);
    }
  }

  void timerEvent(QTimerEvent* e) override {
    auto it = timers_.find(e->timerId());
    if (it == timers_.end()) return;
    FlutterTask task = it.value();
    timers_.erase(it);
    killTimer(e->timerId());
    RunTask(task);
  }

  void exposeEvent(QExposeEvent*) override {
    if (isExposed() && !started_) {
      started_ = true;
      StartEngine();
    }
  }

  void resizeEvent(QResizeEvent*) override { SendMetrics(); }

  void touchEvent(QTouchEvent* event) override {
    if (!engine_) return;
    for (const QTouchEvent::TouchPoint& p : event->touchPoints()) {
      FlutterPointerPhase phase;
      switch (p.state()) {
        case Qt::TouchPointPressed: phase = kDown; break;
        case Qt::TouchPointMoved: phase = kMove; break;
        case Qt::TouchPointReleased: phase = kUp; break;
        default: continue;
      }
      FlutterPointerEvent e = {};
      e.struct_size = sizeof(e);
      e.phase = phase;
      e.timestamp = FlutterEngineGetCurrentTime() / 1000;
      e.x = p.pos().x();
      e.y = p.pos().y();
      e.device = p.id();
      e.device_kind = kFlutterPointerDeviceKindTouch;
      e.buttons = phase == kUp ? 0 : kFlutterPointerButtonMousePrimary;
      FlutterEngineSendPointerEvent(engine_, &e, 1);
    }
    event->accept();
  }

  void keyPressEvent(QKeyEvent* e) override {
    VLOG("runner: key press key=%d text='%s' client=%d\n", e->key(), qPrintable(e->text()),
            has_client_);
    if (!has_client_) return;
    switch (e->key()) {
      case Qt::Key_Backspace:
        DeleteBackward();
        break;
      case Qt::Key_Delete:
        DeleteForward();
        break;
      case Qt::Key_Left:
        MoveCursor(-1);
        break;
      case Qt::Key_Right:
        MoveCursor(1);
        break;
      case Qt::Key_Return:
      case Qt::Key_Enter:
        if (multiline_) {
          ReplaceSelection("\n");
        } else {
          SendAction(input_action_);
        }
        break;
      default:
        // Hardware keyboards deliver printable characters here.
        if (!e->text().isEmpty() && e->text().at(0).isPrint()) ReplaceSelection(e->text());
        break;
    }
  }

 private:
  // ---- Engine start ------------------------------------------------------

  void StartEngine() {
    pixel_ratio_ = ComputePixelRatio();

    FlutterRendererConfig renderer = {};
    renderer.type = kOpenGL;
    renderer.open_gl.struct_size = sizeof(renderer.open_gl);
    renderer.open_gl.make_current = [](void* u) { return static_cast<Runner*>(u)->MakeCurrent(); };
    renderer.open_gl.clear_current = [](void* u) { return static_cast<Runner*>(u)->ClearCurrent(); };
    renderer.open_gl.present = [](void* u) { return static_cast<Runner*>(u)->Present(); };
    renderer.open_gl.fbo_callback = [](void*) -> uint32_t { return 0; };
    renderer.open_gl.make_resource_current = [](void* u) {
      return static_cast<Runner*>(u)->MakeResourceCurrent();
    };
    renderer.open_gl.gl_proc_resolver = [](void* u, const char* name) -> void* {
      return static_cast<Runner*>(u)->ProcAddress(name);
    };

    QByteArray assets = assets_.toUtf8();
    QByteArray icu = icu_.toUtf8();
    FlutterProjectArgs args = {};
    args.struct_size = sizeof(args);
    args.assets_path = assets.constData();
    args.icu_data_path = icu.constData();

    // Release/profile engines run precompiled app code from an AOT ELF library.
    QByteArray aot = aot_.toUtf8();
    FlutterEngineAOTData aot_data = nullptr;
    if (!aot_.isEmpty()) {
      FlutterEngineAOTDataSource source = {};
      source.type = kFlutterEngineAOTDataSourceTypeElfPath;
      source.elf_path = aot.constData();
      if (FlutterEngineCreateAOTData(&source, &aot_data) != kSuccess) {
        fprintf(stderr, "runner: loading AOT library %s failed\n", aot.constData());
        QGuiApplication::exit(1);
        return;
      }
      args.aot_data = aot_data;
    }
    args.log_message_callback = [](const char* tag, const char* message, void*) {
      fprintf(stderr, "[%s] %s\n", tag, message);
    };
    args.log_tag = "flutter";
    args.platform_message_callback = [](const FlutterPlatformMessage* m, void* u) {
      static_cast<Runner*>(u)->OnPlatformMessage(m);
    };

    platform_runner_.struct_size = sizeof(platform_runner_);
    platform_runner_.user_data = this;
    platform_runner_.runs_task_on_current_thread_callback = [](void*) {
      return QThread::currentThread() == QCoreApplication::instance()->thread();
    };
    platform_runner_.post_task_callback = [](FlutterTask task, uint64_t target, void* u) {
      static_cast<Runner*>(u)->PostPlatformTask(task, target);
    };
    platform_runner_.identifier = 1;
    task_runners_.struct_size = sizeof(task_runners_);
    task_runners_.platform_task_runner = &platform_runner_;
    args.custom_task_runners = &task_runners_;

    FlutterEngineResult r = FlutterEngineRun(FLUTTER_ENGINE_VERSION, &renderer, &args, this, &engine_);
    if (r != kSuccess || !engine_) {
      fprintf(stderr, "runner: FlutterEngineRun failed (%d)\n", static_cast<int>(r));
      engine_ = nullptr;
      QGuiApplication::exit(1);
      return;
    }
    SendMetrics();
    SendLifecycle(QGuiApplication::applicationState());
  }

  double ComputePixelRatio() {
    if (const char* env = getenv("FLUTTER_PIXEL_RATIO")) return atof(env);
    double ratio = screen()->physicalDotsPerInch() / 160.0;
    return ratio < 1.0 ? 1.0 : (ratio > 4.0 ? 4.0 : ratio);
  }

  void SendMetrics() {
    if (!engine_) return;
    FlutterWindowMetricsEvent m = {};
    m.struct_size = sizeof(m);
    // The compositor may not have sized the window yet; fall back to the screen.
    QSize size = this->size();
    if (size.isEmpty()) size = screen()->size();
    // Qt on Sailfish reports sizes in device pixels already (devicePixelRatio 1),
    // so the pixel ratio only tells Flutter how to scale logical pixels.
    m.width = static_cast<size_t>(size.width());
    m.height = static_cast<size_t>(size.height());
    m.pixel_ratio = pixel_ratio_;

    QInputMethod* im = QGuiApplication::inputMethod();
    if (im->isVisible()) {
      int h = im->keyboardRectangle().height();
      m.physical_view_inset_bottom = h > size.height() ? 0 : h;
    }
    fprintf(stderr, "runner: metrics %zux%zu ratio=%.2f keyboard=%.0f\n", m.width, m.height,
            pixel_ratio_, m.physical_view_inset_bottom);
    FlutterEngineSendWindowMetricsEvent(engine_, &m);
  }

  // ---- Lifecycle ---------------------------------------------------------

  void SendLifecycle(Qt::ApplicationState state) {
    if (!engine_) return;
    const char* s = "AppLifecycleState.resumed";
    switch (state) {
      case Qt::ApplicationActive: s = "AppLifecycleState.resumed"; break;
      case Qt::ApplicationInactive: s = "AppLifecycleState.inactive"; break;
      case Qt::ApplicationHidden: s = "AppLifecycleState.hidden"; break;
      case Qt::ApplicationSuspended: s = "AppLifecycleState.paused"; break;
    }
    fprintf(stderr, "runner: lifecycle %s\n", s);
    FlutterPlatformMessage msg = {};
    msg.struct_size = sizeof(msg);
    msg.channel = "flutter/lifecycle";
    msg.message = reinterpret_cast<const uint8_t*>(s);
    msg.message_size = strlen(s);
    FlutterEngineSendPlatformMessage(engine_, &msg);
  }

  // ---- Platform channels -------------------------------------------------

  void Respond(const FlutterPlatformMessageResponseHandle* handle, const QByteArray& data) {
    if (handle) {
      FlutterEngineSendPlatformMessageResponse(engine_, handle,
                                               reinterpret_cast<const uint8_t*>(data.constData()),
                                               static_cast<size_t>(data.size()));
    }
  }

  void RespondOk(const FlutterPlatformMessageResponseHandle* handle,
                 const QJsonValue& result = QJsonValue()) {
    QJsonArray envelope;
    envelope.append(result);
    Respond(handle, QJsonDocument(envelope).toJson(QJsonDocument::Compact));
  }

  void HandleMessage(MessageEvent* m) {
    VLOG("runner: message on %s (%d bytes) %s\n", qPrintable(m->channel), m->data.size(),
            qPrintable(QString::fromUtf8(m->data.left(100))));
    if (!engine_) return;
    if (m->channel == "flutter/textinput" || m->channel == "flutter/platform") {
      QJsonObject call = QJsonDocument::fromJson(m->data).object();
      QString method = call.value("method").toString();
      QJsonValue args = call.value("args");
      if (m->channel == "flutter/textinput") {
        VLOG("runner: textinput %s\n", qPrintable(method));
        HandleTextInput(method, args, m->handle);
      } else {
        HandlePlatform(method, args, m->handle);
      }
      return;
    }
    // Unhandled channels: an empty response means "not implemented".
    Respond(m->handle, QByteArray());
  }

  void HandlePlatform(const QString& method, const QJsonValue& args,
                      const FlutterPlatformMessageResponseHandle* handle) {
    QClipboard* clipboard = QGuiApplication::clipboard();
    if (method == "SystemNavigator.pop") {
      RespondOk(handle);
      QGuiApplication::quit();
    } else if (method == "Clipboard.setData") {
      clipboard->setText(args.toObject().value("text").toString());
      RespondOk(handle);
    } else if (method == "Clipboard.getData") {
      QJsonObject o;
      o.insert("text", clipboard->text());
      RespondOk(handle, o);
    } else if (method == "Clipboard.hasStrings") {
      QJsonObject o;
      o.insert("value", !clipboard->text().isEmpty());
      RespondOk(handle, o);
    } else if (method.startsWith("SystemChrome.") || method.startsWith("HapticFeedback.") ||
               method == "SystemSound.play") {
      RespondOk(handle);  // Accepted and ignored.
    } else {
      Respond(handle, QByteArray());
    }
  }

  // ---- Text input --------------------------------------------------------

  void HandleTextInput(const QString& method, const QJsonValue& args,
                       const FlutterPlatformMessageResponseHandle* handle) {
    QInputMethod* im = QGuiApplication::inputMethod();
    if (method == "TextInput.setClient") {
      QJsonArray a = args.toArray();
      client_id_ = a.at(0).toInt();
      QJsonObject config = a.at(1).toObject();
      has_client_ = true;
      multiline_ = config.value("inputType").toObject().value("name").toString() ==
                   "TextInputType.multiline";
      input_action_ = config.value("inputAction").toString("TextInputAction.done");
      hints_ = Qt::ImhNone;
      if (config.value("obscureText").toBool()) hints_ |= Qt::ImhHiddenText | Qt::ImhNoPredictiveText;
      if (!config.value("autocorrect").toBool(true)) hints_ |= Qt::ImhNoPredictiveText;
      QString type = config.value("inputType").toObject().value("name").toString();
      if (type == "TextInputType.number") hints_ |= Qt::ImhDigitsOnly;
      if (type == "TextInputType.emailAddress") hints_ |= Qt::ImhEmailCharactersOnly | Qt::ImhNoAutoUppercase;
      if (type == "TextInputType.phone") hints_ |= Qt::ImhDialableCharactersOnly;
      if (type == "TextInputType.url") hints_ |= Qt::ImhUrlCharactersOnly | Qt::ImhNoAutoUppercase;
      text_ = QString();
      base_ = extent_ = 0;
      comp_start_ = comp_end_ = -1;
      im->update(Qt::ImQueryAll);
      RespondOk(handle);
    } else if (method == "TextInput.clearClient") {
      has_client_ = false;
      im->hide();
      RespondOk(handle);
    } else if (method == "TextInput.show") {
      requestActivate();
      im->show();
      im->update(Qt::ImQueryAll);
      VLOG(
              "runner: im show: visible=%d animating=%d focusObject=%p window=%p focusWindow=%p "
              "active=%d QT_IM_MODULE=%s locale=%s\n",
              im->isVisible(), im->isAnimating(), static_cast<void*>(QGuiApplication::focusObject()),
              static_cast<void*>(this), static_cast<void*>(QGuiApplication::focusWindow()),
              isActive(), getenv("QT_IM_MODULE") ? getenv("QT_IM_MODULE") : "(unset)",
              qPrintable(im->locale().name()));
      RespondOk(handle);
    } else if (method == "TextInput.hide") {
      im->hide();
      RespondOk(handle);
    } else if (method == "TextInput.setEditingState") {
      QJsonObject s = args.toObject();
      text_ = s.value("text").toString();
      base_ = Clamp(s.value("selectionBase").toInt(-1));
      extent_ = Clamp(s.value("selectionExtent").toInt(-1));
      if (s.value("selectionBase").toInt(-1) < 0) base_ = extent_ = text_.size();
      comp_start_ = s.value("composingBase").toInt(-1);
      comp_end_ = s.value("composingExtent").toInt(-1);
      if (comp_start_ < 0 || comp_end_ < comp_start_ || comp_end_ > text_.size()) {
        comp_start_ = comp_end_ = -1;
      }
      im->update(Qt::ImQueryAll);
      RespondOk(handle);
    } else if (method == "TextInput.setEditableSizeAndTransform") {
      QJsonObject o = args.toObject();
      QJsonArray t = o.value("transform").toArray();
      double r = pixel_ratio_;
      caret_rect_ = QRect(static_cast<int>(t.at(12).toDouble() * r),
                          static_cast<int>(t.at(13).toDouble() * r),
                          static_cast<int>(o.value("width").toDouble() * r),
                          static_cast<int>(o.value("height").toDouble() * r));
      im->update(Qt::ImCursorRectangle);
      RespondOk(handle);
    } else if (method == "TextInput.setCaretRect") {
      RespondOk(handle);
    } else if (method == "TextInput.requestAutofill" || method == "TextInput.finishAutofillContext" ||
               method == "TextInput.setStyle" || method == "TextInput.setMarkedTextRect" ||
               method == "TextInput.updateConfig" || method == "TextInput.setSelectionRects") {
      RespondOk(handle);
    } else {
      Respond(handle, QByteArray());
    }
  }

  int Clamp(int v) const { return v < 0 ? 0 : (v > text_.size() ? text_.size() : v); }

  QVariant InputQuery(Qt::InputMethodQuery q) const {
    switch (q) {
      case Qt::ImEnabled: return has_client_;
      case Qt::ImHints: return static_cast<int>(hints_);
      case Qt::ImCursorRectangle: return caret_rect_;
      case Qt::ImCursorPosition: return extent_;
      case Qt::ImAnchorPosition: return base_;
      case Qt::ImSurroundingText: return text_;
      case Qt::ImCurrentSelection:
        return text_.mid(qMin(base_, extent_), qAbs(extent_ - base_));
      case Qt::ImEnterKeyType: return static_cast<int>(EnterKeyType());
      default: return QVariant();
    }
  }

  Qt::EnterKeyType EnterKeyType() const {
    if (multiline_) return Qt::EnterKeyReturn;
    if (input_action_ == "TextInputAction.go") return Qt::EnterKeyGo;
    if (input_action_ == "TextInputAction.search") return Qt::EnterKeySearch;
    if (input_action_ == "TextInputAction.send") return Qt::EnterKeySend;
    if (input_action_ == "TextInputAction.next") return Qt::EnterKeyNext;
    if (input_action_ == "TextInputAction.previous") return Qt::EnterKeyPrevious;
    return Qt::EnterKeyDone;
  }

  void HandleInputMethod(QInputMethodEvent* e) {
    VLOG("runner: input method event commit='%s' preedit='%s' client=%d\n",
            qPrintable(e->commitString()), qPrintable(e->preeditString()), has_client_);
    if (!has_client_) return;
    // Replace text around the cursor if the input method asks for it.
    if (e->replacementLength() > 0 || e->replacementStart() != 0) {
      int start = Clamp(extent_ + e->replacementStart());
      int end = Clamp(start + e->replacementLength());
      text_.remove(start, end - start);
      base_ = extent_ = start;
      comp_start_ = comp_end_ = -1;
    }
    // Drop the previous composing (preedit) text, then insert the new state.
    if (comp_start_ >= 0) {
      text_.remove(comp_start_, comp_end_ - comp_start_);
      base_ = extent_ = comp_start_;
      comp_start_ = comp_end_ = -1;
    }
    if (!e->commitString().isEmpty()) {
      int start = qMin(base_, extent_), end = qMax(base_, extent_);
      text_.replace(start, end - start, e->commitString());
      base_ = extent_ = start + e->commitString().size();
    }
    if (!e->preeditString().isEmpty()) {
      int start = qMin(base_, extent_), end = qMax(base_, extent_);
      text_.replace(start, end - start, e->preeditString());
      comp_start_ = start;
      comp_end_ = start + e->preeditString().size();
      base_ = extent_ = comp_end_;
    }
    SendEditingState();
    QGuiApplication::inputMethod()->update(Qt::ImSurroundingText | Qt::ImCursorPosition |
                                           Qt::ImAnchorPosition | Qt::ImCurrentSelection);
  }

  void ReplaceSelection(const QString& s) {
    if (comp_start_ >= 0) {
      text_.remove(comp_start_, comp_end_ - comp_start_);
      base_ = extent_ = comp_start_;
      comp_start_ = comp_end_ = -1;
    }
    int start = qMin(base_, extent_), end = qMax(base_, extent_);
    text_.replace(start, end - start, s);
    base_ = extent_ = start + s.size();
    SendEditingState();
    QGuiApplication::inputMethod()->update(Qt::ImQueryInput);
  }

  void DeleteBackward() {
    int start = qMin(base_, extent_), end = qMax(base_, extent_);
    if (start == end && start > 0) {
      start -= (start > 1 && text_.at(start - 1).isLowSurrogate()) ? 2 : 1;
    }
    comp_start_ = comp_end_ = -1;
    text_.remove(start, end - start);
    base_ = extent_ = start;
    SendEditingState();
    QGuiApplication::inputMethod()->update(Qt::ImQueryInput);
  }

  void DeleteForward() {
    int start = qMin(base_, extent_), end = qMax(base_, extent_);
    if (start == end && end < text_.size()) {
      end += text_.at(end).isHighSurrogate() ? 2 : 1;
    }
    comp_start_ = comp_end_ = -1;
    text_.remove(start, end - start);
    base_ = extent_ = start;
    SendEditingState();
    QGuiApplication::inputMethod()->update(Qt::ImQueryInput);
  }

  void MoveCursor(int delta) {
    base_ = extent_ = Clamp(extent_ + delta);
    SendEditingState();
    QGuiApplication::inputMethod()->update(Qt::ImQueryInput);
  }

  void SendEditingState() {
    QJsonObject state;
    state.insert("text", text_);
    state.insert("selectionBase", base_);
    state.insert("selectionExtent", extent_);
    state.insert("selectionAffinity", "TextAffinity.downstream");
    state.insert("selectionIsDirectional", false);
    state.insert("composingBase", comp_start_);
    state.insert("composingExtent", comp_end_);
    QJsonArray args;
    args.append(client_id_);
    args.append(state);
    SendMethod("TextInputClient.updateEditingState", args);
  }

  void SendAction(const QString& action) {
    QJsonArray args;
    args.append(client_id_);
    args.append(action);
    SendMethod("TextInputClient.performAction", args);
  }

  void SendMethod(const char* method, const QJsonArray& args) {
    QJsonObject call;
    call.insert("method", method);
    call.insert("args", args);
    QByteArray data = QJsonDocument(call).toJson(QJsonDocument::Compact);
    FlutterPlatformMessage msg = {};
    msg.struct_size = sizeof(msg);
    msg.channel = "flutter/textinput";
    msg.message = reinterpret_cast<const uint8_t*>(data.constData());
    msg.message_size = static_cast<size_t>(data.size());
    FlutterEngineSendPlatformMessage(engine_, &msg);
  }

  // ---- State -------------------------------------------------------------

  QString assets_, icu_, aot_;
  QOffscreenSurface offscreen_;
  QOpenGLContext* context_ = nullptr;
  QOpenGLContext* resource_context_ = nullptr;
  std::mutex mutex_;
  std::condition_variable cv_;
  FlutterEngine engine_ = nullptr;
  FlutterTaskRunnerDescription platform_runner_ = {};
  FlutterCustomTaskRunners task_runners_ = {};
  QHash<int, FlutterTask> timers_;
  double pixel_ratio_ = 1.0;
  bool started_ = false;
  bool logged_gl_ = false;
  int frames_ = 0;

  // Text input client state (GUI thread only).
  bool has_client_ = false;
  bool multiline_ = false;
  int client_id_ = 0;
  QString input_action_ = "TextInputAction.done";
  Qt::InputMethodHints hints_ = Qt::ImhNone;
  QString text_;
  int base_ = 0, extent_ = 0;
  int comp_start_ = -1, comp_end_ = -1;
  QRect caret_rect_;
};

// Sailjail only lets an app write to ~/.local/share/<Org>/<App>, ~/.config/<Org>/<App> and
// ~/.cache/<Org>/<App>. Writes anywhere else do not fail but are silently discarded, which
// breaks plugins (path_provider, shared_preferences) that use the standard XDG directories.
// Point the XDG base directories at the permitted ones, using the names from the desktop entry.
void RedirectXdgDirsForSailjail(const QString& app_name) {
  QSettings desktop("/usr/share/applications/" + app_name + ".desktop", QSettings::IniFormat);
  QString org = desktop.value("X-Sailjail/OrganizationName").toString();
  QString app = desktop.value("X-Sailjail/ApplicationName").toString();
  const char* home = getenv("HOME");
  if (org.isEmpty() || app.isEmpty() || !home) return;

  struct Dir {
    const char* variable;
    const char* parent;
  };
  const Dir dirs[] = {{"XDG_DATA_HOME", "/.local/share/"},
                      {"XDG_CONFIG_HOME", "/.config/"},
                      {"XDG_CACHE_HOME", "/.cache/"}};
  for (const Dir& d : dirs) {
    QString path = QString::fromLocal8Bit(home) + d.parent + org + "/" + app;
    QDir().mkpath(path);
    qputenv(d.variable, path.toLocal8Bit());
  }
}

}  // namespace

int main(int argc, char** argv) {
  QGuiApplication app(argc, argv);
  QString assets, icu, aot;
  if (argc >= 3) {
    assets = QString::fromLocal8Bit(argv[1]);
    icu = QString::fromLocal8Bit(argv[2]);
    if (argc > 3) aot = QString::fromLocal8Bit(argv[3]);
  } else {
    // Installed layout: this binary is copied to /usr/bin/<app name> and finds
    // its bundle in /usr/share/<app name>/ (needed because Sailjail only starts ELF binaries).
    QString name = QFileInfo(QString::fromLocal8Bit(argv[0])).fileName();
    if (name == "flutter-sailfish-runner") {
      fprintf(stderr, "usage: %s <flutter_assets dir> <icudtl.dat> [libapp.so]\n", argv[0]);
      return 2;
    }
    QString base = "/usr/share/" + name;
    RedirectXdgDirsForSailjail(name);
    assets = base + "/flutter_assets";
    // The sandbox only exposes the app's own /usr/share directory, so prefer a copy shipped there.
    icu = QFileInfo::exists(base + "/icudtl.dat") ? base + "/icudtl.dat"
                                                  : "/usr/share/flutter-sailfish/icudtl.dat";
    if (QFileInfo::exists(base + "/lib/libapp.so")) aot = base + "/lib/libapp.so";
  }
  Runner runner(assets, icu, aot);
  runner.setGeometry(QGuiApplication::primaryScreen()->geometry());
  runner.showFullScreen();
  return app.exec();
}
