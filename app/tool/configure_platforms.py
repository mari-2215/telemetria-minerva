"""Configura os projetos nativos gerados pelo ``flutter create``.

O model_viewer_plus exibe o GLB local por uma origem localhost. Por isso o
Android precisa aceitar apenas localhost em HTTP e o iOS precisa habilitar
views embarcadas. O script é idempotente e usado pelo CI após gerar cada
plataforma.
"""

from __future__ import annotations

import argparse
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ANDROID_NS = "http://schemas.android.com/apk/res/android"


def configure_android() -> None:
    app_dir = ROOT / "android" / "app"
    kotlin_build = app_dir / "build.gradle.kts"
    groovy_build = app_dir / "build.gradle"

    if kotlin_build.exists():
        contents = kotlin_build.read_text(encoding="utf-8")
        updated, changes = re.subn(
            r"minSdk\s*=\s*flutter\.minSdkVersion",
            "minSdk = 24",
            contents,
        )
        if changes == 0 and not re.search(r"minSdk\s*=\s*(?:24|2[5-9]|[3-9]\d)", contents):
            raise RuntimeError("Não foi possível localizar minSdk em build.gradle.kts")
        kotlin_build.write_text(updated, encoding="utf-8")
    elif groovy_build.exists():
        contents = groovy_build.read_text(encoding="utf-8")
        updated, changes = re.subn(
            r"minSdkVersion\s+flutter\.minSdkVersion",
            "minSdkVersion 24",
            contents,
        )
        if changes == 0 and not re.search(r"minSdkVersion\s+(?:24|2[5-9]|[3-9]\d)", contents):
            raise RuntimeError("Não foi possível localizar minSdkVersion em build.gradle")
        groovy_build.write_text(updated, encoding="utf-8")
    else:
        raise FileNotFoundError("Projeto Android ainda não foi gerado")

    manifest = app_dir / "src" / "main" / "AndroidManifest.xml"
    if not manifest.exists():
        raise FileNotFoundError(manifest)
    ET.register_namespace("android", ANDROID_NS)
    tree = ET.parse(manifest)
    application = tree.getroot().find("application")
    if application is None:
        raise RuntimeError("Elemento <application> não encontrado no manifest")
    application.set(
        f"{{{ANDROID_NS}}}networkSecurityConfig",
        "@xml/network_security_config",
    )
    tree.write(manifest, encoding="utf-8", xml_declaration=True)

    network_config = app_dir / "src" / "main" / "res" / "xml" / "network_security_config.xml"
    network_config.parent.mkdir(parents=True, exist_ok=True)
    network_config.write_text(
        """<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="true">localhost</domain>
        <domain includeSubdomains="true">127.0.0.1</domain>
    </domain-config>
</network-security-config>
""",
        encoding="utf-8",
    )


def configure_ios() -> None:
    info_plist = ROOT / "ios" / "Runner" / "Info.plist"
    if not info_plist.exists():
        raise FileNotFoundError("Projeto iOS ainda não foi gerado")
    with info_plist.open("rb") as source:
        contents = plistlib.load(source)
    contents["io.flutter.embedded_views_preview"] = True
    with info_plist.open("wb") as destination:
        plistlib.dump(contents, destination, sort_keys=False)


def configure_web() -> None:
    index = ROOT / "web" / "index.html"
    if not index.exists():
        raise FileNotFoundError("Projeto Web ainda não foi gerado")
    contents = index.read_text(encoding="utf-8")
    script = (
        '  <script type="module" '
        'src="./assets/packages/model_viewer_plus/assets/model-viewer.min.js" '
        'defer></script>'
    )
    if script not in contents:
        if "</head>" not in contents:
            raise RuntimeError("Elemento </head> não encontrado em web/index.html")
        contents = contents.replace("</head>", f"{script}\n</head>", 1)
        index.write_text(contents, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "platform",
        nargs="+",
        choices=("android", "ios", "web", "all"),
    )
    args = parser.parse_args()
    platforms = set(args.platform)
    if "all" in platforms:
        platforms = {"android", "ios", "web"}

    if "android" in platforms:
        configure_android()
    if "ios" in platforms:
        configure_ios()
    if "web" in platforms:
        configure_web()


if __name__ == "__main__":
    main()
