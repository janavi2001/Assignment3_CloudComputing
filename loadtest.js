import http from "k6/http";
import { check, sleep } from "k6";

export let options = {
  vus: 10,
  duration: "30s",
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<500"],
  },
};

export default function () {
  const payload = JSON.stringify({
    name: `item-${__VU}-${Date.now()}`,
    value: Math.floor(Math.random() * 1000),
  });

  const headers = { "Content-Type": "application/json" };

  const createRes = http.post("http://localhost:8080/items", payload, { headers });
  check(createRes, { "create succeeded": (r) => r.status === 201 });

  const body = createRes.json();
  if (body && body.id) {
    const getRes = http.get(`http://localhost:8080/items/${body.id}`);
    check(getRes, { "get succeeded": (r) => r.status === 200 });
  }

  sleep(1);
}
