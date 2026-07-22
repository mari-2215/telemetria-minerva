from __future__ import annotations

import argparse
import json
from pathlib import Path
import secrets
import shlex
from urllib.parse import urlencode

import qrcode
from PIL import Image, ImageDraw, ImageFont


def strong_token() -> str:
    return secrets.token_urlsafe(64)


def qr_payload(server: str, token: str, role: str) -> str:
    return "minerva://login?" + urlencode(
        {"server": server.rstrip("/"), "token": token, "role": role}
    )


def render_qr(payload: str, title: str, output: Path) -> None:
    qr = qrcode.QRCode(
        version=None,
        error_correction=qrcode.constants.ERROR_CORRECT_H,
        box_size=10,
        border=4,
    )
    qr.add_data(payload)
    qr.make(fit=True)
    image = qr.make_image(fill_color="#05084A", back_color="white").convert("RGB")

    canvas = Image.new("RGB", (image.width, image.height + 90), "white")
    canvas.paste(image, (0, 0))
    draw = ImageDraw.Draw(canvas)
    title_font = ImageFont.load_default(size=24)
    small_font = ImageFont.load_default(size=15)
    draw.text(
        (canvas.width / 2, image.height + 20),
        title,
        fill="#05084A",
        anchor="ma",
        font=title_font,
    )
    draw.text(
        (canvas.width / 2, image.height + 55),
        "Telemetria Minerva — acesso confidencial",
        fill="#334155",
        anchor="ma",
        font=small_font,
    )
    canvas.save(output)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Gera tokens fortes e QR Codes da Telemetria Minerva."
    )
    parser.add_argument("--server", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--env-output", type=Path, required=True)
    args = parser.parse_args()

    server = args.server.rstrip("/")
    if server.split(":", 1)[0] not in {"http", "https"}:
        raise SystemExit("O servidor deve começar com http:// ou https://")

    captain = strong_token()
    crew = strong_token()
    mapping = {
        captain: {"name": "Capitã", "role": "captain"},
        crew: {"name": "Tripulação", "role": "crew"},
    }

    args.output.mkdir(parents=True, exist_ok=True)
    args.output.chmod(0o700)
    args.env_output.parent.mkdir(parents=True, exist_ok=True)

    json_value = json.dumps(mapping, ensure_ascii=False, separators=(",", ":"))
    args.env_output.write_text(
        "# Gerado automaticamente. Não publicar no Git.\n"
        f"export MINERVA_ACCESS_TOKENS_JSON={shlex.quote(json_value)}\n",
        encoding="utf-8",
    )
    args.env_output.chmod(0o600)

    credentials = {
        "server": server,
        "captain_token": captain,
        "crew_token": crew,
        "captain_qr_payload": qr_payload(server, captain, "captain"),
        "crew_qr_payload": qr_payload(server, crew, "crew"),
    }
    credentials_path = args.output / "credentials.json"
    credentials_path.write_text(
        json.dumps(credentials, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    credentials_path.chmod(0o600)

    captain_qr = args.output / "capitao.png"
    crew_qr = args.output / "tripulacao.png"
    render_qr(credentials["captain_qr_payload"], "CAPITÃO", captain_qr)
    render_qr(credentials["crew_qr_payload"], "TRIPULAÇÃO", crew_qr)
    captain_qr.chmod(0o600)
    crew_qr.chmod(0o600)

    readme = (
        "CREDENCIAIS DA TELEMETRIA MINERVA\n\n"
        f"Servidor: {server}\n\n"
        f"Token do capitão:\n{captain}\n\n"
        f"Token da tripulação:\n{crew}\n\n"
        "Os QR Codes estão em capitao.png e tripulacao.png.\n"
        "Não envie essas imagens para grupos públicos e não as versione no Git.\n\n"
        f"Para iniciar a API:\nsource {args.env_output}\nminerva-api\n"
    )
    readme_path = args.output / "LEIA-ME.txt"
    readme_path.write_text(readme, encoding="utf-8")
    readme_path.chmod(0o600)

    print(f"Credenciais: {args.output}")
    print(f"Variável da API: {args.env_output}")
    print("Tokens antigos deixam de funcionar após reiniciar a API.")


if __name__ == "__main__":
    main()
