const express = require("express");
const admin = require("firebase-admin");
const bodyParser = require("body-parser");
const cors = require("cors");

// 🌐 Инициализация Express
const app = express();
app.use(cors());
app.use(bodyParser.json());

// 🧠 Диагностика окружения и Firebase
console.log("🟢 Push Server booting...");
console.log("🧩 Firebase projectId:", "menro-msg");
console.log("🔑 GOOGLE_APPLICATION_CREDENTIALS:", process.env.GOOGLE_APPLICATION_CREDENTIALS);

try {
  admin.initializeApp({
    credential: admin.credential.applicationDefault(),
    projectId: "menro-msg",
  });
  console.log("✅ Firebase initialized successfully");
} catch (initError) {
  console.error("❌ Firebase initialization failed:", initError);
}

app.post("/send-push", async (req, res) => {
  const timestamp = new Date().toISOString();
  const clientIp = req.headers["x-forwarded-for"] || req.socket.remoteAddress;

  console.log("📥 Incoming push request at:", timestamp);
  console.log("🌐 Request from IP:", clientIp);
  console.log("📦 Request body:", JSON.stringify(req.body, null, 2));
  console.log("🧾 Headers:", JSON.stringify(req.headers, null, 2));

  const { token, title, body } = req.body;

  if (!token || !title || !body) {
    console.warn("⚠️ Missing required fields");
    return res.status(400).json({
      error: "Missing fields: token, title or body",
      received: { token, title, body },
      at: timestamp,
    });
  }

  const message = {
    token,
    notification: { title, body },
    data: { click_action: "FLUTTER_NOTIFICATION_CLICK" },
  };

  console.log("🚀 Prepared message:", JSON.stringify(message, null, 2));

  try {
    const response = await admin.messaging().send(message);
    console.log("✅ Push sent successfully, ID:", response);
    return res.json({ success: true, messageId: response, at: timestamp });
  } catch (error) {
    console.error("🔥 Push send failed");
    console.error("📛 Error message:", error.message);
    console.error("📄 Stack trace:", error.stack);
    console.error("🔎 Firebase credentials path:", process.env.GOOGLE_APPLICATION_CREDENTIALS);

    return res.status(500).json({
      error: error.message,
      stack: error.stack,
      hint: "Проверь токен, projectId и путь к ключу. Возможно, Firebase не смог авторизоваться.",
      time: timestamp,
    });
  }
});

// 🚀 Запуск сервера
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`🔥 Push Server running on port ${PORT}`);
});