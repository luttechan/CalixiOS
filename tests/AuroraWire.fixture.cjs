const assert = require("node:assert/strict");
const { createCipheriv, createDecipheriv, randomBytes } = require("node:crypto");
const { writeFileSync } = require("node:fs");
const { createServer } = require("node:http");

const key = randomBytes(32);
let receipt;
let polls = 0;
const server = createServer(async (request, response) => {
  try {
    assert.equal(request.method, "POST");
    assert.equal(request.headers["content-type"], "application/octet-stream");
    const route = request.url.slice(1);
    assert.ok(["offer", "result", "received"].includes(route));
    const pieces = [];
    let size = 0;
    for await (const chunk of request) {
      size += chunk.length;
      assert.ok(size <= 4096);
      pieces.push(chunk);
    }
    const frame = Buffer.concat(pieces);
    const decipher = createDecipheriv("aes-256-gcm", key, frame.subarray(0, 12));
    decipher.setAAD(Buffer.from("calix-vesper-v3:" + route));
    decipher.setAuthTag(frame.subarray(-16));
    const data = JSON.parse(Buffer.concat([decipher.update(frame.subarray(12, -16)), decipher.final()]));
    if (route === "offer") {
      assert.match(data.receipt, /^[a-f0-9]{32}$/);
      assert.equal(data.changes.event["m:fixture"].value.title, "Vesper 개강 준비");
      receipt = data.receipt;
    } else if (route === "result") {
      assert.equal(data.receipt, receipt);
      polls++;
    } else {
      assert.equal(data.receipt, receipt);
      assert.ok(polls > 1);
    }
    const ready = polls > 1;
    const reply = { receipt, phase: route === "received" ? "received" : ready ? "complete" : "approval" };
    if (ready && route === "result") {
      reply.snapshot = {
        records: { event: { "manual:fixture": { revision: "aurora-fixture", value: { title: "Aurora에서 보낸 일정" } } } },
        conflicts: [], school: [], attendance: [], owner: "", mainTerm: "2026학년도 2학기",
      };
    }
    const nonce = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", key, nonce);
    cipher.setAAD(Buffer.from("calix-vesper-v3:reply"));
    const bytes = Buffer.concat([nonce, cipher.update(JSON.stringify(reply)), cipher.final(), cipher.getAuthTag()]);
    response.writeHead(200, { "Content-Type": "application/octet-stream", "Content-Length": bytes.length });
    response.end(bytes);
  } catch (error) {
    console.error(`Aurora fixture rejected a request: ${error.code ?? error.name}`);
    response.writeHead(400);
    response.end();
  }
});

server.listen(0, "127.0.0.1", () => {
  const token = new URLSearchParams({
    v: "3", host: "127.0.0.1", port: String(server.address().port),
    expires: String(Math.floor(Date.now() / 1000) + 240), computer: "0123456789abcdef".repeat(2),
    key: key.toString("base64url"),
  });
  writeFileSync(process.argv[2], "calix-vesper://pair?" + token.toString(), { mode: 0o600 });
});
