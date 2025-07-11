class Message {
  final String text;
  final String senderId;
  final String receiverId;
  final int timestamp;
  final bool isRead;

  Message({
    required this.text,
    required this.senderId,
    required this.receiverId,
    required this.timestamp,
    this.isRead = false,
  });

  // Проверка, принадлежит ли сообщение текущему пользователю
  bool isMine(String currentUserId) => senderId == currentUserId;

  // Преобразование в JSON-объект
  Map<String, dynamic> toJson() => {
        'text': text,
        'senderId': senderId,
        'receiverId': receiverId,
        'timestamp': timestamp,
        'isRead': isRead,
      };

  // Обратное преобразование из JSON
  factory Message.fromJson(Map<String, dynamic> json) => Message(
        text: json['text'],
        senderId: json['senderId'],
        receiverId: json['receiverId'],
        timestamp: json['timestamp'],
        isRead: json['isRead'] ?? false,
      );
}