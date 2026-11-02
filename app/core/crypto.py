from cryptography.fernet import Fernet

from app.core.config import settings

_fernet = Fernet(settings.fernet_key.encode())


def encrypt_str(value: str) -> str:
    return _fernet.encrypt(value.encode()).decode()


def decrypt_str(value: str) -> str:
    return _fernet.decrypt(value.encode()).decode()
