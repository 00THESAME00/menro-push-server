import 'dart:convert';
import 'package:http/http.dart' as http;

/// Отправляет push-уведомление через локальный Node.js сервер
Future<void> sendPush(String token, String title, String body) async {
  // ⚠️ Укажи свой IP вместо localhost — ты уже нашёл: 192.168.1.101
  final url = Uri.parse('http://192.168.1.101:3000/send-push');

  try {
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'token': token,
        'title': title,
        'body': body,
      }),
    );

    if (response.statusCode == 200) {
      print('✅ Уведомление отправлено: ${response.body}');
    } else {
      print('❌ Ошибка отправки: ${response.statusCode} → ${response.body}');
    }
  } catch (e) {
    print('⚠️ Не удалось подключиться к серверу: $e');
  }
}