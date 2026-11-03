interface Env {
  EMAIL: SendEmail;
  CRASH_REPORT_SECRET?: string;
}

const FROM = "crash@softbuydeals.in";
// Email Routing rule on softbuydeals.in forwards admin@ -> ghodke.mangesh2@gmail.com
const TO = "ghodke.mangesh2@gmail.com";

function cors(status: number, body: string): Response {
  return new Response(body, {
    status,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") return cors(204, "");
    if (request.method !== "POST") return cors(200, "DreamPlayer crash report endpoint\n");

    // Optional shared-secret check: if CRASH_REPORT_SECRET is set on the
    // worker, the app must send Authorization: Bearer <secret>.
    if (env.CRASH_REPORT_SECRET) {
      const auth = request.headers.get("Authorization") ?? "";
      if (auth !== `Bearer ${env.CRASH_REPORT_SECRET}`) {
        return cors(401, "unauthorized\n");
      }
    }

    let form: FormData;
    try {
      form = await request.formData();
    } catch {
      return cors(400, "expected multipart/form-data\n");
    }

    const message = String(form.get("message") ?? "");
    const platform = String(form.get("platform") ?? "");
    const appVersion = String(form.get("appVersion") ?? "");
    const logs = form.getAll("logs").filter((f): f is File => f instanceof File);
    if (logs.length === 0) return cors(400, "no log files attached\n");

    const totalBytes = logs.reduce((n, f) => n + f.size, 0);
    const text = [
      `DreamPlayer crash report`,
      `App version: ${appVersion || "unknown"}  Platform: ${platform || "unknown"}`,
      `Logs: ${logs.map((f) => `${f.name} (${f.size} B)`).join(", ")}  total ${totalBytes} B`,
      "",
      message || "(no message)",
    ].join("\n");

    const attachments = await Promise.all(
      logs.map(async (f) => ({
        filename: f.name,
        content: await f.arrayBuffer(),
        type: f.type || "text/plain",
        disposition: "attachment",
      })),
    );

    try {
      await env.EMAIL.send({
        from: FROM,
        to: TO,
        subject: `DreamPlayer crash report ${appVersion || ""} (${platform || "?"})`,
        text,
        attachments,
      });
    } catch (e) {
      return cors(502, `email failed: ${String(e)}\n`);
    }
    return cors(200, "ok\n");
  },
};
