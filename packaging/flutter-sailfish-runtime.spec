Name:       flutter-sailfish-runtime
Summary:    Flutter runtime (engine and runner) for Sailfish OS
Version:    0.1.0
Release:    5
License:    BSD-3-Clause
URL:        https://github.com/flutter/flutter
BuildArch:  aarch64
AutoReqProv: no

%description
Flutter engine 3.47.8 (release, linux-arm64) and a Qt based runner that hosts
Flutter applications on Sailfish OS. Proof of concept.

%prep

%build

%install
mkdir -p %{buildroot}/usr/bin %{buildroot}/usr/libexec/flutter-sailfish %{buildroot}/usr/share/flutter-sailfish
install -m 755 %{stage}/flutter-sailfish-runner %{buildroot}/usr/bin/flutter-sailfish-runner
install -m 755 %{stage}/libflutter_engine.so %{buildroot}/usr/libexec/flutter-sailfish/libflutter_engine.so
install -m 644 %{stage}/icudtl.dat %{buildroot}/usr/share/flutter-sailfish/icudtl.dat

%files
%defattr(-,root,root,-)
/usr/bin/flutter-sailfish-runner
/usr/libexec/flutter-sailfish/libflutter_engine.so
/usr/share/flutter-sailfish/icudtl.dat
