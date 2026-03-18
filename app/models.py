from datetime import datetime

from sqlalchemy import BigInteger, Column, DateTime, Integer, String
from sqlalchemy.orm import declarative_base

Base = declarative_base()


class Item(Base):
    __tablename__ = "items"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(255), nullable=False, unique=True)
    value = Column(Integer, nullable=False)
    created_at = Column(DateTime(timezone=True), default=datetime.utcnow, nullable=False)
