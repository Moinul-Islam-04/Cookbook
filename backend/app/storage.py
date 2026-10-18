"""Object storage behind a small interface: S3 (the server) or in-memory (tests and local
development). The database stores stable object keys, never URLs."""

from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Iterator, Protocol


class StorageError(Exception):
    """The object store failed or is unreachable (maps to 503, retryable)."""


@dataclass(frozen=True)
class StoredObject:
    key: str
    last_modified: datetime


class ObjectStore(Protocol):
    def put(self, key: str, data: bytes, content_type: str) -> None: ...
    def get(self, key: str) -> bytes: ...
    def delete(self, key: str) -> None: ...
    def list(self, prefix: str) -> Iterator[StoredObject]: ...


class S3Store:
    def __init__(self, endpoint_url: str, access_key: str, secret_key: str, bucket: str, region: str) -> None:
        import boto3
        from botocore.config import Config

        self.bucket = bucket
        self._client = boto3.client(
            "s3",
            endpoint_url=endpoint_url,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            region_name=region,
            config=Config(connect_timeout=5, read_timeout=30, retries={"max_attempts": 2},
                          s3={"addressing_style": "path"}),
        )

    def ensure_bucket(self) -> None:
        from botocore.exceptions import ClientError

        try:
            self._client.head_bucket(Bucket=self.bucket)
        except ClientError:
            # Private by default: no bucket policy, so nothing is publicly readable.
            self._client.create_bucket(Bucket=self.bucket)

    def _call(self, fn, **kwargs):
        from botocore.exceptions import BotoCoreError, ClientError

        try:
            return fn(Bucket=self.bucket, **kwargs)
        except (BotoCoreError, ClientError) as e:
            raise StorageError(type(e).__name__) from e

    def put(self, key: str, data: bytes, content_type: str) -> None:
        self._call(self._client.put_object, Key=key, Body=data, ContentType=content_type)

    def get(self, key: str) -> bytes:
        return self._call(self._client.get_object, Key=key)["Body"].read()

    def delete(self, key: str) -> None:
        self._call(self._client.delete_object, Key=key)

    def list(self, prefix: str) -> Iterator[StoredObject]:
        token = None
        while True:
            kwargs = {"Prefix": prefix, **({"ContinuationToken": token} if token else {})}
            page = self._call(self._client.list_objects_v2, **kwargs)
            for obj in page.get("Contents", []):
                yield StoredObject(obj["Key"], obj["LastModified"])
            if not page.get("IsTruncated"):
                return
            token = page["NextContinuationToken"]


@dataclass
class MemoryStore:
    objects: dict[str, tuple[bytes, str, datetime]] = field(default_factory=dict)
    fail: bool = False  # tests flip this to simulate an outage

    def _check(self) -> None:
        if self.fail:
            raise StorageError("simulated outage")

    def put(self, key: str, data: bytes, content_type: str) -> None:
        self._check()
        self.objects[key] = (data, content_type, datetime.now(UTC))

    def get(self, key: str) -> bytes:
        self._check()
        if key not in self.objects:
            raise StorageError("NoSuchKey")
        return self.objects[key][0]

    def delete(self, key: str) -> None:
        self._check()
        self.objects.pop(key, None)

    def list(self, prefix: str) -> Iterator[StoredObject]:
        self._check()
        for key, (_, _, modified) in list(self.objects.items()):
            if key.startswith(prefix):
                yield StoredObject(key, modified)


def make_store(settings) -> ObjectStore:
    if settings.storage_backend == "memory":
        return MemoryStore()
    if settings.storage_backend == "s3":
        store = S3Store(settings.s3_endpoint_url, settings.s3_access_key, settings.s3_secret_key,
                        settings.s3_bucket, settings.s3_region)
        store.ensure_bucket()
        return store
    raise RuntimeError(f"Unknown COOKBOOK_STORAGE_BACKEND {settings.storage_backend!r}; use 's3' or 'memory'.")
