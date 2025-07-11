const express = require('express');
const admin = require('firebase-admin');
const bodyParser = require('body-parser');
const app = express();
const port = 3000;

const serviceAccount = require('./service-account.json');
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

app.use(bodyParser.json());

app.post('/send-push', async (req, res) => {
  const { token, title, body } = req.body;

  try {
    const message = {
      token,
      notification: { title, body },
      data: { click_action: 'FLUTTER_NOTIFICATION_CLICK' }
    };

    const response = await admin.messaging().send(message);
    console.log('✅ Push sent:', response);
    res.json({ success: true, id: response });
  } catch (error) {
    console.error('❌ Push error:', error);
    res.status(500).json({ error: error.message });
  }
});

app.listen(port, () => {
  console.log(`🚀 Push сервер работает: http://localhost:${port}`);
});