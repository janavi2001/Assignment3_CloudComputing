import os

"""Containers & Deployment assignment - HW3."""
from flask import Flask, jsonify, request, abort
from sqlalchemy import text

from app.db import get_session, init_db
from app.models import Item


def create_app() -> Flask:
    app = Flask(__name__)

    @app.route("/health", methods=["GET"])
    def health():
        """Health endpoint: returns 200 only if DB is reachable."""
        try:
            with get_session() as session:
                # simple query to validate connectivity
                session.execute(text("SELECT 1"))
            return jsonify({"status": "ok", "db": "connected"}), 200
        except Exception as e:
            return jsonify({"status": "error", "db": "unavailable", "error": str(e)}), 503

    @app.route("/items", methods=["POST"])
    def create_item():
        payload = request.get_json(force=True)
        if not payload or "name" not in payload or "value" not in payload:
            abort(400, "Missing name and value")

        item = Item(name=payload["name"], value=payload["value"])
        with get_session() as session:
            session.add(item)
            session.commit()
            session.refresh(item)

        return jsonify({"id": item.id, "name": item.name, "value": item.value}), 201

    @app.route("/items/<int:item_id>", methods=["GET"])
    def get_item(item_id: int):
        with get_session() as session:
            item = session.get(Item, item_id)
            if not item:
                abort(404)
            return jsonify({"id": item.id, "name": item.name, "value": item.value})

    return app


app = create_app()


if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
