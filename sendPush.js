const express = require("express");
const admin = require("firebase-admin");
const bodyParser = require("body-parser");
const cors = require("cors");
const path = require("path");

// 🔑 Замените на свой путь и имя JSON-файла из Firebase
const serviceAccount = require(path.join(__dirname, "service-account.json"));

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  projectId: "menro-msg"
});

const app = express();
app.use(cors());
app.use(bodyParser.json());

app.post("/send-push", async (req, res) => {
  const { token, title, body } = req.body;

  if (!token || !title || !body) {
    return res.status(400).json({
      error: "Missing fields: token, title or body"
    });
  }

  try {
    const message = {
      token,
      notification: { title, body },
      data: { click_action: "FLUTTER_NOTIFICATION_CLICK" }
    };

    const response = await admin.messaging().send(message);
    console.log("✅ Push sent:", response);
    return res.json({ success: true, id: response });
  } catch (error) {
    console.error("❌ Firebase Push Error:", error);
    return res.status(500).json({ error: error.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`🔥 Push Server running on port ${PORT}`));