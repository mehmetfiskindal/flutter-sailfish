Name:       harbour-flutter-counter
Summary:    Flutter counter example for Sailfish OS
Version:    0.1.0
Release:    8
License:    BSD-3-Clause
URL:        https://github.com/flutter/flutter
BuildArch:  aarch64
AutoReqProv: no
Requires:   flutter-sailfish-runtime

%description
Counter example built with Flutter (AOT, release).

%prep

%build

%install
mkdir -p %{buildroot}/usr/bin %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/%{name}/lib %{buildroot}/usr/share/icons/hicolor/86x86/apps
cp -r %{stage}/flutter_assets %{buildroot}/usr/share/%{name}/flutter_assets
install -m 644 %{stage}/libapp.so %{buildroot}/usr/share/%{name}/lib/libapp.so
install -m 644 %{stage}/icudtl.dat %{buildroot}/usr/share/%{name}/icudtl.dat
install -m 755 %{stage}/flutter-sailfish-runner %{buildroot}/usr/bin/%{name}
install -m 644 %{stage}/%{name}.desktop %{buildroot}/usr/share/applications/%{name}.desktop
install -m 644 %{stage}/%{name}.png %{buildroot}/usr/share/icons/hicolor/86x86/apps/%{name}.png

%files
%defattr(-,root,root,-)
/usr/bin/%{name}
/usr/share/%{name}
/usr/share/applications/%{name}.desktop
/usr/share/icons/hicolor/86x86/apps/%{name}.png
