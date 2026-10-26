#!/bin/sh
# Builds the runtime and app RPMs for the aarch64 Sailfish target inside the SDK build engine.
#
#   REPO=<repository root as seen from the container> sh build-rpm.sh
#
# Run as user mersdk in the build engine container. Inputs, all produced earlier:
#   dist/aot/app/flutter-sailfish-runner, icudtl.dat, libflutter_engine.so   (runner, engine)
#   dist/aot/app/flutter_assets, libapp.so                                   (flutter-sailfish build)
#   dist/aot/app/plugins/*.so                                                (native plugins, optional)
#   dist/aot/app/sailjail-permissions.txt                                    (one name per line, optional)
# The desktop entry template in packaging/desktop-entry gets its "Permissions=" line filled in
# from the permissions file, so that what plugins asked for reaches the installed app.
# Output: ~/rpmtop/RPMS/aarch64/*.rpm
set -e
: "${REPO:?set REPO to the repository root as seen from the container}"
TARGET=${SFOS_TARGET:-SailfishOS-5.1.0.11-aarch64}
APP=${APP_NAME:-harbour-flutter-counter}
DIST=$REPO/dist/aot/app
S=$HOME/rpmstage
T=$HOME/rpmtop

rm -rf "$S" "$T"
mkdir -p "$S/rt" "$S/app/plugins" "$T/BUILD" "$T/RPMS" "$T/SPECS" "$T/SOURCES" "$T/SRPMS"

cp "$DIST/flutter-sailfish-runner" "$DIST/libflutter_engine.so" "$DIST/icudtl.dat" "$S/rt/"
cp -r "$DIST/flutter_assets" "$S/app/flutter_assets"
cp "$DIST/libapp.so" "$DIST/flutter-sailfish-runner" "$DIST/icudtl.dat" "$S/app/"
cp "$DIST"/plugins/*.so "$S/app/plugins/" 2>/dev/null || echo "no native plugins"
cp "$REPO/packaging/desktop-entry/$APP.png" "$S/app/"
cp "$REPO"/packaging/*.spec "$T/SPECS/"

# Desktop entry: Permissions=A;B;C; from the permission list, empty when there is none.
PERMISSIONS=""
if [ -f "$DIST/sailjail-permissions.txt" ]; then
  PERMISSIONS=$(tr -d '\r' < "$DIST/sailjail-permissions.txt" | grep -v '^$' | tr '\n' ';')
fi
sed "s|^Permissions=.*|Permissions=$PERMISSIONS|" "$REPO/packaging/desktop-entry/$APP.desktop" > "$S/app/$APP.desktop"
echo "desktop entry: $(grep '^Permissions=' "$S/app/$APP.desktop")"

for pair in "flutter-sailfish-runtime:rt" "$APP:app"; do
  name=${pair%%:*}
  dir=${pair##*:}
  sb2 -t "$TARGET" -m sdk-build rpmbuild -bb --target aarch64 \
    --define "_topdir $T" --define "stage $S/$dir" \
    --define "__os_install_post %{nil}" --define "_build_id_links none" \
    --define "debug_package %{nil}" --define "__strip /bin/true" \
    "$T/SPECS/$name.spec" 2>&1 | tail -3
done

find "$T/RPMS" -name '*.rpm' -exec ls -l {} \;
