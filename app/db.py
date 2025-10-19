import asyncpg
import os


class Database:
    def __init__(self):
        self.pool = None

    async def init_pool(self):
        self.pool = await asyncpg.create_pool(
            user=os.getenv("DB_USER"),
            password=os.getenv("DB_PASS"),
            database=os.getenv("DB_NAME"),
            host=os.getenv("DB_HOST"),
        )

        async with self.pool.acquire() as conn:
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS users (
                    result integer PRIMARY KEY,
                    versionCode integer
                )
                """
            )

    async def add_result(self, result: int, version_code: int):
        """
        Добавляет результат в таблицу
        """
        async with self.pool.acquire() as conn:
            await conn.execute(
                """
                INSERT INTO users(result, versionCode)
                VALUES($1, $2)
                ON CONFLICT (result) DO NOTHING
                """,
                result,
                version_code,
            )

    async def get_percentile(self, result: int, version_code: int) -> float:
        """
        Возвращает процент пользователей чьи результаты меньше данного.
        """
        async with self.pool.acquire() as conn:
            total = await conn.fetchval(
                "SELECT COUNT(*) FROM users WHERE versionCode=$1", version_code
            )
            if total == 0:
                return 0.0
            better = await conn.fetchval(
                "SELECT COUNT(*) FROM users WHERE versionCode=$1 AND result < $2",
                version_code,
                result,
            )
            percentile = (better / total) * 100
            return percentile
