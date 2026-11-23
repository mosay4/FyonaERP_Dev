from typing import BinaryIO, Optional
import io
from .config import settings
from .logging import get_logger
import asyncio

logger = get_logger("storage")


class StorageBackend:
    async def upload(self, path: str, data: BinaryIO, content_type: str) -> str:
        raise NotImplementedError

    async def download(self, path: str) -> Optional[bytes]:
        raise NotImplementedError

    async def delete(self, path: str) -> bool:
        raise NotImplementedError

    async def list_files(self, prefix: str) -> list[str]:
        raise NotImplementedError


class S3Storage(StorageBackend):
    def __init__(self):
        import boto3
        from botocore.config import Config as BotoConfig

        session = boto3.Session(
            aws_access_key_id=settings.S3_ACCESS_KEY,
            aws_secret_access_key=settings.S3_SECRET_KEY,
            region_name=settings.S3_REGION,
        )
        # Short timeouts so an unreachable object store fails fast instead of
        # blocking the request for minutes (boto3 defaults are ~60s+).
        self.client = session.client(
            "s3",
            endpoint_url=settings.S3_ENDPOINT_URL,
            config=BotoConfig(
                connect_timeout=4,
                read_timeout=12,
                retries={"max_attempts": 2, "mode": "standard"},
            ),
        )
        self.bucket = settings.S3_BUCKET

    async def upload(self, path: str, data: BinaryIO, content_type: str) -> str:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(
            None,
            self.client.upload_fileobj,
            data,
            self.bucket,
            path,
            {"ContentType": content_type},
        )
        return f"{self.bucket}/{path}"

    async def download(self, path: str) -> Optional[bytes]:
        loop = asyncio.get_event_loop()
        response = await loop.run_in_executor(
            None, self.client.get_object, self.bucket, path
        )
        return response["Body"].read()

    async def delete(self, path: str) -> bool:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, self.client.delete_object, self.bucket, path)
        return True

    async def list_files(self, prefix: str) -> list[str]:
        loop = asyncio.get_event_loop()
        response = await loop.run_in_executor(
            None, self.client.list_objects_v2, self.bucket, prefix
        )
        return [obj["Key"] for obj in response.get("Contents", [])]


class MinioStorage(StorageBackend):
    def __init__(self):
        from minio import Minio

        endpoint = settings.S3_ENDPOINT_URL or "localhost:9000"
        secure = endpoint.startswith("https") if endpoint else False
        host = endpoint.replace("https://", "").replace("http://", "")
        # Shorter timeouts so a down MinIO fails fast (defaults can hang ~60s).
        try:
            from urllib3 import Timeout as _Timeout
            timeout = _Timeout(connect=4, read=12)
            http_client = None
            from minio import Minio as _Minio
            # Minio accepts an http_client; fall back to default if incompatible.
            try:
                http_client = _Minio._get_http_client(
                    timeout=timeout, max_retries=2
                )
            except Exception:
                http_client = None
            kwargs = {
                "access_key": settings.S3_ACCESS_KEY,
                "secret_key": settings.S3_SECRET_KEY,
                "secure": secure,
            }
            if http_client is not None:
                kwargs["http_client"] = http_client
            self.client = Minio(host, **kwargs)
        except Exception:
            self.client = Minio(
                host,
                access_key=settings.S3_ACCESS_KEY,
                secret_key=settings.S3_SECRET_KEY,
                secure=secure,
            )
        self.bucket = settings.S3_BUCKET
        try:
            if not self.client.bucket_exists(self.bucket):
                self.client.make_bucket(self.bucket)
        except Exception as e:
            logger.warning("minio_bucket_init", error=str(e))

    async def upload(self, path: str, data: BinaryIO, content_type: str) -> str:
        loop = asyncio.get_event_loop()
        content = data.read() if hasattr(data, "read") else data
        await loop.run_in_executor(
            None,
            lambda: self.client.put_object(
                self.bucket, path, io.BytesIO(content), len(content), content_type
            ),
        )
        return f"{self.bucket}/{path}"

    async def download(self, path: str) -> Optional[bytes]:
        loop = asyncio.get_event_loop()
        response = await loop.run_in_executor(
            None, self.client.get_object, self.bucket, path
        )
        return response.read()

    async def delete(self, path: str) -> bool:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, self.client.remove_object, self.bucket, path)
        return True

    async def list_files(self, prefix: str) -> list[str]:
        loop = asyncio.get_event_loop()
        objects = await loop.run_in_executor(
            None, self.client.list_objects, self.bucket, prefix
        )
        return [obj.object_name for obj in objects]


class LocalStorage(StorageBackend):
    """Local filesystem storage — fallback when MinIO/S3 is not configured."""

    def __init__(self, base_dir: str):
        import os
        self.base_dir = os.path.abspath(base_dir)
        os.makedirs(self.base_dir, exist_ok=True)

    async def upload(self, path: str, data: BinaryIO, content_type: str) -> str:
        import os
        full = os.path.join(self.base_dir, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        if hasattr(data, "read"):
            content = data.read()
        else:
            content = data
        with open(full, "wb") as f:
            f.write(content)
        return path

    async def download(self, path: str) -> Optional[bytes]:
        import os
        full = os.path.join(self.base_dir, path)
        if not os.path.isfile(full):
            return None
        with open(full, "rb") as f:
            return f.read()

    async def delete(self, path: str) -> bool:
        import os
        full = os.path.join(self.base_dir, path)
        if os.path.isfile(full):
            os.remove(full)
            return True
        return False

    async def list_files(self, prefix: str) -> list[str]:
        import os
        results = []
        full_prefix = os.path.join(self.base_dir, prefix)
        for root, _, files in os.walk(full_prefix):
            for f in files:
                rel = os.path.relpath(os.path.join(root, f), self.base_dir)
                results.append(rel.replace("\\", "/"))
        return results


_storage: Optional[StorageBackend] = None


def get_storage() -> StorageBackend:
    global _storage
    if _storage is None:
        backend = settings.STORAGE_BACKEND
        if backend in ("minio", "s3") and settings.S3_ENDPOINT_URL and settings.S3_ACCESS_KEY:
            if backend == "minio":
                _storage = MinioStorage()
            else:
                _storage = S3Storage()
        else:
            from .paths import UPLOAD_ROOT
            _storage = LocalStorage(UPLOAD_ROOT)
    return _storage


async def unified_upload(category: str, filename: str, content: bytes, content_type: str) -> str:
    """Upload a file via the configured storage backend.

    Returns the storage-relative path that can later be used with unified_download().
    """
    storage = get_storage()
    data = io.BytesIO(content)
    storage_key = f"{category}/{filename}"
    await storage.upload(storage_key, data, content_type)
    return storage_key


async def unified_download(storage_key: str) -> Optional[bytes]:
    """Download a file by its storage-relative path."""
    return await get_storage().download(storage_key)


async def unified_delete(storage_key: str) -> bool:
    """Delete a file by its storage-relative path."""
    return await get_storage().delete(storage_key)
