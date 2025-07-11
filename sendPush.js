const admin = require('firebase-admin');

// 🔑 Заменить путь на твой JSON файл из Firebase
const serviceAccount = require('./service-account.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const token = 'FCM_ТОКЕН_ПОЛУЧАТЕЛЯ';
const message = {
  notification: {
    title: '💬 Сообщение от Менро',
    body: 'Привет, как дела?',
  },
  data: {
    senderId: '123456',
    click_action: 'FLUTTER_NOTIFICATION_CLICK',
  },
  token: token,
};

admin.messaging().send(message)
  .then((response) => {
    console.log('✅ Уведомление отправлено:', response);
  })
  .catch((error) => {
    console.error('❌ Ошибка при отправке:', error);
  });