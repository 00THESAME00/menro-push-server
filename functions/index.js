const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

exports.sendPush = functions.https.onRequest(async (req, res) => {
  const {token, title, body} = req.body;

  if (!token || !title || !body) {
    return res.status(400).send("❌ Missing fields");
  }

  try {
    const message = {
      token,
      notification: {title, body},
      data: {click_action: "FLUTTER_NOTIFICATION_CLICK"},
    };

    const response = await admin.messaging().send(message);
    console.log("✅ Push sent:", response);
    return res.json({success: true, id: response});
  } catch (error) {
    console.error("❌ Push error:", error);
    return res.status(500).json({error: error.message});
  }
});
