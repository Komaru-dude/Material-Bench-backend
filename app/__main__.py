import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI
from pydantic import BaseModel
from .db import Database

logging.basicConfig(level=logging.INFO)
logging.info("Запускаюсь...")

db = Database()

@asynccontextmanager
async def lifespan(app: FastAPI):
    logging.info("Инициализация БД...")
    await db.init_pool()
    logging.info("БД успешно инициализировалась.")
    yield
    if db.pool:
        await db.pool.close()
        logging.info("Пул БД закрыт.")

app = FastAPI(lifespan=lifespan)

class ScoreRequest(BaseModel):
    score: int
    versionCode: int

@app.post("/getRank")
async def rank(req: ScoreRequest):
    percentile = await db.get_percentile(req.score, req.versionCode)
    return {"percentile": round(percentile, 2)}

@app.post("/submit")
async def submit(req: ScoreRequest):
    try:
        await db.add_result(req.score, req.versionCode)
        return {"message": True}
    except Exception as e:
        logging.error(f"Ошибка при добавлении результата: {e}")
        return {"message": False}
