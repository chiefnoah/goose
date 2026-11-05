{ lib, stdenv, cmake, ninja, python3, writeShellScriptBin, version }:

let
  source = paths: lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions paths;
  };

  meta = {
    homepage = "https://github.com/aardappel/goose";
    license = lib.licenses.asl20;
    platforms = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ];
  };

  goose = stdenv.mkDerivation {
    pname = "goose";
    inherit version;
    src = source [ ../CMakeLists.txt ../cmake ../src ../third_party ../stdlib ];

    nativeBuildInputs = [ cmake ninja ];
    cmakeFlags = [
      (lib.cmakeFeature "GOOSE_VERSION" version)
      (lib.cmakeFeature "GOOSE_TCC_LIB_PATH" "${placeholder "out"}/lib/goose/tcclib")
      (lib.cmakeFeature "GOOSE_BUILTIN_LIBS" "")
    ];
    enableParallelBuilding = true;

    # Keep the standard library in the layout that the compiler already searches.
    installPhase = ''
      runHook preInstall
      install -Dm755 goose "$out/bin/goose"
      mkdir -p "$out/lib/goose"
      cp -R tcclib "$out/lib/goose/"
      cp -R ../stdlib "$out/stdlib"
      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      export GOOSE_HOME="$TMPDIR/goose-home"
      cd "$TMPDIR"
      printf 'import std;\nfn main() { print(clamp(3, 1, 9)); }\n' > smoke.goose
      "$out/bin/goose" --version
      "$out/bin/goose" check smoke.goose
      test "$("$out/bin/goose" run smoke.goose)" = 3
      runHook postInstallCheck
    '';

    meta = meta // {
      description = "Goose programming language compiler";
      license = [ lib.licenses.asl20 lib.licenses.lgpl21Plus ];
      mainProgram = "goose";
    };
  };

  goose-lsp = stdenv.mkDerivation {
    pname = "goose-lsp";
    inherit version;
    src = source [ ../tools/lsp ../stdlib ../test/lsp_goose.py ];

    nativeBuildInputs = [ goose ];
    nativeInstallCheckInputs = [ python3 ];
    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      export GOOSE_HOME="$TMPDIR/goose-home"
      goose build --cc "$CC" --stdlib "${goose}/stdlib" -o goose-lsp tools/lsp/main.goose
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 goose-lsp "$out/bin/goose-lsp"
      ln -s "${goose}/stdlib" "$out/stdlib"
      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      mkdir -p build
      python3 test/lsp_goose.py --server "$out/bin/goose-lsp"
      python3 ${./check-lsp.py} "$out/bin/goose-lsp" "${goose}/stdlib"
      runHook postInstallCheck
    '';

    meta = meta // {
      description = "Goose language server written in Goose";
      mainProgram = "goose-lsp";
    };
  };

  # The C++ server shares the compiler binary and its runtime resources.
  goose-lsp-cpp = (writeShellScriptBin "goose-lsp-cpp" ''
    exec ${goose}/bin/goose lsp "$@"
  '').overrideAttrs (old: {
    nativeInstallCheckInputs = [ python3 ];
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      "$out/bin/goose-lsp-cpp" --probe | grep -Fx 'goose lsp 3.17'
      python3 ${./check-lsp.py} "$out/bin/goose-lsp-cpp" "${goose}/stdlib"
      runHook postInstallCheck
    '';
    meta = (old.meta or { }) // meta // {
      description = "Goose language server written in C++";
      mainProgram = "goose-lsp-cpp";
    };
  });
in
{
  inherit goose goose-lsp goose-lsp-cpp;
  default = goose;
}
