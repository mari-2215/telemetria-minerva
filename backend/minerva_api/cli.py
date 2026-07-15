from __future__ import annotations

import os


def main() -> None:
    try:
        import uvicorn
    except ImportError as exc:
        raise SystemExit("uvicorn nao instalado; execute pip install -e .") from exc
    uvicorn.run(
        "minerva_api.app:create_app",
        factory=True,
        host=os.getenv("MINERVA_BIND", "0.0.0.0"),
        port=int(os.getenv("MINERVA_PORT", "8080")),
    )


if __name__ == "__main__":
    main()

