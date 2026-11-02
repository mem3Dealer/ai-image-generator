import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    database_path: Path
    images_dir: Path
    assets_dir: Path


def load_settings() -> Settings:
    backend_root = Path(__file__).resolve().parents[1]
    data_dir = Path(os.environ.get("DATA_DIR", str(backend_root / "data")))
    database_path = Path(os.environ.get("DATABASE_PATH", str(data_dir / "app.db")))
    images_dir = Path(os.environ.get("IMAGES_DIR", str(data_dir / "images")))
    assets_dir = Path(os.environ.get("ASSETS_DIR", str(backend_root / "assets")))
    return Settings(database_path=database_path, images_dir=images_dir, assets_dir=assets_dir)
