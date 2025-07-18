import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';  // ← этот импорт можно оставить, он не мешает
// остальные твои импорты…
import 'models/message.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class Global {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  static void handlePushMessage(RemoteMessage message, {required bool fromTap}) {
    final senderId = message.notification?.title ?? message.data['senderId'];
    final text = message.notification?.body ?? message.data['text'];
    print('🔔 PUSH: $senderId → $text');

    if (fromTap && senderId != null) {
      navigatorKey.currentState?.push(MaterialPageRoute(
        builder: (_) => ChatScreen(
          chat: ChatEntry(id: senderId, name: null),
          currentUserId: senderId,
        ),
      ));
    }
  }

  static Future<void> initFirebaseMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    final token = await messaging.getToken();
    print("📲 Получен FCM токен: $token");

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      handlePushMessage(message, fromTap: false);
    });
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      handlePushMessage(message, fromTap: true);
    });
  }
}

class ChatService {
  final _db = FirebaseFirestore.instance;

  Future<void> sendMessage({
    required String senderId,
    required String receiverId,
    required String text,
    String? receiverName,
  }) async {
    print("📤 Отправка от $senderId → $receiverId: $text");
    final chatId = _getChatId(senderId, receiverId);
    final doc = _db.collection('chats').doc(chatId).collection('messages').doc();

    final msg = Message(
      text: text,
      senderId: senderId,
      receiverId: receiverId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await doc.set(msg.toJson());
    print("✅ Сообщение добавлено в чат $chatId");

    await _createChatEntry(senderId, receiverId, name: receiverName);
    await _createChatEntry(receiverId, senderId);
    print("📁 Чат обновлён для обоих");

    final receiverDoc = await _db.collection('users').doc(receiverId).get();
    final token = receiverDoc.data()?['fcmToken'];
    if (token != null && token.toString().isNotEmpty) {
      print("📲 FCM токен найден: $token");
      await _sendPushNotification(token, senderId, text);
    } else {
      print("⚠️ Push не отправлен — токен отсутствует");
    }
  }

  Future<void> _sendPushNotification(String token, String senderId, String message) async {
    final url = Uri.parse('https://menro-server.onrender.com/send-push');
    try {
      print("🔔 Отправка push...");
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': token,
          'title': senderId,
          'body': message,
        }),
      );
      print("📦 Render статус: ${response.statusCode}");
      print("📨 Render ответ: ${response.body}");
    } catch (e) {
      print("❌ Ошибка push-запроса: $e");
    }
  }

  Stream<List<Message>> getMessagesStream(String user1, String user2) {
    final chatId = _getChatId(user1, user2);
    return _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp')
        .snapshots()
        .map((snap) => snap.docs.map((d) => Message.fromJson(d.data())).toList());
  }

  Future<void> _createChatEntry(String ownerId, String peerId, {String? name}) async {
    final userDoc = _db.collection('users').doc(ownerId);
    final chatDoc = userDoc.collection('chatList').doc(peerId);

    final exists = await chatDoc.get();
    if (!exists.exists) {
      await chatDoc.set({
        'peerId': peerId,
        'name': name,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Stream<List<ChatEntry>> getUserChats(String userId) {
    return _db
        .collection('users')
        .doc(userId)
        .collection('chatList')
        .orderBy('createdAt')
        .snapshots()
        .map((snap) => snap.docs.map((doc) {
              final data = doc.data();
              return ChatEntry(
                id: data['peerId'],
                name: data['name'],
              );
            }).toList());
  }

  String _getChatId(String id1, String id2) {
    final sorted = [id1, id2]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  Future<void> deleteChatLocally(String ownerId, String peerId) async {
    print("🗑️ Удаляем чат у $ownerId → $peerId");
    final userDoc = _db.collection('users').doc(ownerId);
    final chatDoc = userDoc.collection('chatList').doc(peerId);
    await chatDoc.delete();
    print("✅ Чат $peerId удалён из списка $ownerId");
  }

  Future<void> clearChatMessages(String user1, String user2) async {
    final chatId = _getChatId(user1, user2);
    final messagesRef = _db.collection('chats').doc(chatId).collection('messages');
    final batch = _db.batch();
    final snap = await messagesRef.get();
    for (var doc in snap.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
    print("🧹 Все сообщения в чате $chatId удалены");
  }
}

class ChatEntry {
  final String id;
  final String? name;

  ChatEntry({required this.id, this.name});

  Map<String, dynamic> toJson() => {
        'peerId': id,
        if (name != null) 'name': name,
      };

  factory ChatEntry.fromJson(Map<String, dynamic> json) => ChatEntry(
        id: json['peerId'] ?? json['id'] ?? 'unknown',
        name: json['name'],
      );

  ChatEntry copyWith({String? id, String? name}) {
    return ChatEntry(
      id: id ?? this.id,
      name: name ?? this.name,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatEntry &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name;

  @override
  int get hashCode => id.hashCode ^ name.hashCode;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  Future<String?> _loadSavedUserId() async {
    print("📦 Загружаем userId из SharedPreferences...");
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString('userId');
      print("🔑 Найден userId: $id");
      return id;
    } catch (e) {
      print("❌ Ошибка при загрузке userId: $e");
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Messenger',
      theme: ThemeData.dark(),
      home: FutureBuilder<String?>(
        future: _loadSavedUserId(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              backgroundColor: Colors.black,
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final savedId = snapshot.data;
          if (savedId != null && savedId.isNotEmpty) {
            return ChatListScreen(currentUserId: savedId);
          } else {
            return const WelcomeScreen();
          }
        },
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await Global.initFirebaseMessaging();
  runApp(const MyApp());
}

// 1. Welcome Screen

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Center(
            child: Text(
              'Добро пожаловать',
              style: TextStyle(
                fontSize: 28,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Positioned(
            bottom: 30,
            right: 30,
            child: GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const EnterYourIdScreen(),
                  ),
                );
              },
              child: Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.rectangle,
                ),
                child: const Icon(Icons.arrow_forward, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// 2. Enter Your ID Screen

class EnterYourIdScreen extends StatefulWidget {
  const EnterYourIdScreen({super.key});

  @override
  State<EnterYourIdScreen> createState() => _EnterYourIdScreenState();
}


class _EnterYourIdScreenState extends State<EnterYourIdScreen> {
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();

  String? _statusMessage;
  bool _isLoading = false;
  bool _isExistingUser = false;

  Future<void> _checkId(String id) async {
    if (id.length != 6) {
      setState(() {
        _statusMessage = null;
        _isExistingUser = false;
      });
      return;
    }

    final doc = await FirebaseFirestore.instance.collection('users').doc(id).get();
    setState(() {
      _isExistingUser = doc.exists;
      _statusMessage = doc.exists ? '🔑 Профиль найден' : '🆕 Будет создан новый профиль';
    });
  }

  Future<void> _proceed() async {
    final id = _idController.text.trim();
    final password = _passwordController.text;

    if (id.length != 6 || password.length < 4) {
      setState(() => _statusMessage = 'ID и пароль обязательны');
      return;
    }

    setState(() => _isLoading = true);

    final docRef = FirebaseFirestore.instance.collection('users').doc(id);
    final snapshot = await docRef.get();

    if (snapshot.exists) {
      final stored = snapshot.data();
      if (stored?['password'] != password) {
        setState(() {
          _statusMessage = '❌ Неверный пароль';
          _isLoading = false;
        });
        return;
      }
    } else {
      await docRef.set({'password': password});
      setState(() {
        _statusMessage = '✅ Профиль создан';
      });
    }

    // 💾 Сохраняем ID пользователя для автологина
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('userId', id);

    await _saveFcmToken(id);

    // 📥 Обработка входящих push-сообщений
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final data = message.data;

      if (data.containsKey('text') && data.containsKey('senderId')) {
        final msg = Message(
          text: data['text'],
          senderId: data['senderId'],
          receiverId: id,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );

        ChatService().sendMessage(
          senderId: msg.senderId,
          receiverId: msg.receiverId,
          text: msg.text,
        );
      }
    });

    setState(() => _isLoading = false);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => ChatListScreen(currentUserId: id)),
    );
  }

  Future<void> _saveFcmToken(String userId) async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await FirebaseFirestore.instance.collection('users').doc(userId).set(
          {'fcmToken': token},
          SetOptions(merge: true),
        );
        print("📲 FCM токен сохранён: $token");
      } else {
        print("⚠️ Не удалось получить токен");
      }
    } catch (e) {
      print("❌ Ошибка при сохранении FCM токена: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Введите ваш код и пароль',
                  style: TextStyle(fontSize: 26, color: Colors.white),
                ),
                const SizedBox(height: 32),
                _buildTextField(
                  controller: _idController,
                  hint: '6-значный код (например: 123456)',
                  keyboardType: TextInputType.number,
                  onChanged: _checkId,
                ),
                const SizedBox(height: 16),
                _buildTextField(
                  controller: _passwordController,
                  hint: 'Пароль',
                  obscureText: true,
                ),
                const SizedBox(height: 12),
                if (_statusMessage != null)
                  Text(
                    _statusMessage!,
                    style: TextStyle(
                      color: _isExistingUser ? Colors.green : Colors.blueAccent,
                      fontSize: 16,
                    ),
                  ),
              ],
            ),
            Positioned(
              bottom: 30,
              right: 30,
              child: GestureDetector(
                onTap: _isLoading ? null : _proceed,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: _isLoading ? Colors.grey : Colors.black,
                    shape: BoxShape.rectangle,
                  ),
                  child: _isLoading
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.arrow_forward, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    bool obscureText = false,
    TextInputType? keyboardType,
    void Function(String)? onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        onChanged: onChanged,
        keyboardType: keyboardType,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.grey),
        ),
      ),
    );
  }
}
// 3. Chat List Screen

class ChatListScreen extends StatefulWidget {
  final String currentUserId;
  const ChatListScreen({super.key, required this.currentUserId});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with TickerProviderStateMixin {
  late final Stream<List<ChatEntry>> _chatStream;
  Timer? _longPressTimer;
  ChatEntry? _selectedChat;
  bool _isSubMenuOpen = false;

  @override
  void initState() {
    super.initState();
    _chatStream = ChatService().getUserChats(widget.currentUserId);
  }

  void _openChat(ChatEntry chat) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(chat: chat, currentUserId: widget.currentUserId),
      ),
    );
  }

  Future<void> _addNewChat() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AddFriendFlow(currentUserId: widget.currentUserId),
      ),
    );
    if (result is ChatEntry) _openChat(result);
  }

  void _goToLogin() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const EnterYourIdScreen()),
    );
  }

  void _handlePress(ChatEntry chat) {
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 1200), () {
      setState(() {
        _selectedChat = chat;
        _isSubMenuOpen = false;
      });
    });
  }

  void _cancelPress() => _longPressTimer?.cancel();

  void _clearChat() async {
    if (_selectedChat == null) return;
    await ChatService()
        .clearChatMessages(widget.currentUserId, _selectedChat!.id);
    setState(() {
      _selectedChat = null;
      _isSubMenuOpen = false;
    });
  }

  void _deleteChat() async {
    if (_selectedChat == null) return;
    await ChatService()
        .deleteChatLocally(widget.currentUserId, _selectedChat!.id);
    setState(() {
      _selectedChat = null;
      _isSubMenuOpen = false;
    });
  }

  void _renameChat() {
    // твоя логика переименования
    setState(() {
      _selectedChat = null;
      _isSubMenuOpen = false;
    });
  }

  void _toggleSubMenu() {
    setState(() => _isSubMenuOpen = !_isSubMenuOpen);
  }

  void _closeAll() {
    setState(() {
      _selectedChat = null;
      _isSubMenuOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.grey[900],

      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(68),
        child: SafeArea(
          top: true,
          child: Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: IconButton(
                        key: ValueKey(_selectedChat != null),
                        icon: Icon(
                          _selectedChat != null
                              ? Icons.close
                              : Icons.arrow_back_ios_new,
                          color: Colors.white,
                        ),
                        onPressed: _selectedChat != null
                            ? _closeAll
                            : _goToLogin,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Чаты (${widget.currentUserId})',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 18),
                      ),
                    ),
                    if (_selectedChat != null)
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined,
                                color: Colors.white),
                            onPressed: _renameChat,
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.white),
                            onPressed: _deleteChat,
                          ),
                          IconButton(
                            icon: const Icon(Icons.more_vert,
                                color: Colors.white),
                            onPressed: _toggleSubMenu,
                          ),
                        ],
                      ),
                  ],
                ),

                // ПОДМЕНЮ: узкое, не на всю ширину
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  child: _isSubMenuOpen && _selectedChat != null
                      ? Align(
                          alignment: Alignment.topRight,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.85),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(
                                vertical: 8, horizontal: 12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                TextButton.icon(
                                  onPressed: _clearChat,
                                  icon: const Icon(Icons.cleaning_services_outlined,
                                      color: Colors.white),
                                  label: const Text('Очистить чат',
                                      style: TextStyle(color: Colors.white)),
                                ),
                                TextButton.icon(
                                  onPressed: null,
                                  icon: const Icon(Icons.hourglass_bottom_outlined,
                                      color: Colors.white38),
                                  label: const Text('Coming soon...',
                                      style:
                                          TextStyle(color: Colors.white38)),
                                ),
                              ],
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),

      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_isSubMenuOpen) _closeAll();
        },
        child: StreamBuilder<List<ChatEntry>>(
          stream: _chatStream,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final chats = snapshot.data ?? [];
            if (chats.isEmpty) {
              return const Center(
                child: Text('У тебя пока нет чатов',
                    style: TextStyle(color: Colors.white70)),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              itemCount: chats.length,
              separatorBuilder: (_, __) => const SizedBox(height: 14),
              itemBuilder: (_, index) {
                final chat = chats[index];
                final label =
                    chat.name?.isNotEmpty == true ? chat.name! : chat.id;
                return GestureDetector(
                  onTap: () {
                    if (_isSubMenuOpen) {
                      _closeAll();
                    } else {
                      _openChat(chat);
                    }
                  },
                  onLongPressStart: (_) => _handlePress(chat),
                  onLongPressEnd: (_) => _cancelPress(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(label,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 18)),
                  ),
                );
              },
            );
          },
        ),
      ),

      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.black,
        onPressed: _addNewChat,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}

// 4. Основной экран добавления друга
class AddFriendScreen extends StatefulWidget {
  const AddFriendScreen({super.key});

  @override
  State<AddFriendScreen> createState() => _AddFriendScreenState();
}

class _AddFriendScreenState extends State<AddFriendScreen> {
  final TextEditingController _codeController = TextEditingController();
  bool _isValid = false;

  void _onCodeChanged(String value) {
    setState(() {
      final isSixDigits = RegExp(r'^\d{6}$').hasMatch(value);
      _isValid = isSixDigits;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('Добавить друга'),
        backgroundColor: Colors.black,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Пожалуйста, введите код друга',
                  style: TextStyle(fontSize: 22, color: Colors.white),
                ),
                const SizedBox(height: 24),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _codeController,
                    maxLength: 6,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white, letterSpacing: 3),
                    decoration: const InputDecoration(
                      counterText: '',
                      border: InputBorder.none,
                      hintText: '— — — — — —',
                      hintStyle: TextStyle(color: Colors.grey, letterSpacing: 6),
                    ),
                    onChanged: _onCodeChanged,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _isValid ? 'ID выглядит правильно' : 'Введите 6 цифр',
                  style: TextStyle(
                    color: _isValid ? Colors.green : Colors.redAccent,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            Positioned(
              bottom: 30,
              right: 30,
              child: GestureDetector(
                onTap: _isValid
                    ? () {
                        final friendId = _codeController.text;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Добавляем $friendId...')),
                        );
                      }
                    : null,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: _isValid ? Colors.black : Colors.grey[800],
                    shape: BoxShape.rectangle,
                  ),
                  child: Icon(Icons.arrow_forward,
                      color: _isValid ? Colors.white : Colors.grey),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
class FriendNameScreen extends StatefulWidget {
  const FriendNameScreen({super.key});

  @override
  State<FriendNameScreen> createState() => _FriendNameScreenState();
}

class _FriendNameScreenState extends State<FriendNameScreen> {
  final TextEditingController _nameController = TextEditingController();

  void _submit() {
    final friendName = _nameController.text.trim();

    // Здесь можно сохранить имя и перейти к чату
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Сохраняем имя: ${friendName.isEmpty ? "Без имени" : friendName}')),
    );

    // Переход можно добавить сюда
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('Имя друга'),
        backgroundColor: Colors.black,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Имя друга (не обязательно)',
                  style: TextStyle(fontSize: 22, color: Colors.white),
                ),
                const SizedBox(height: 24),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Например: Макс, Соня, Командир',
                      hintStyle: TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              ],
            ),
            Positioned(
              bottom: 30,
              right: 30,
              child: GestureDetector(
                onTap: _submit,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: const BoxDecoration(
                    color: Colors.black,
                    shape: BoxShape.rectangle,
                  ),
                  child: const Icon(Icons.arrow_forward, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class AddFriendFlow extends StatefulWidget {
  final String currentUserId;

  const AddFriendFlow({super.key, required this.currentUserId});

  @override
  State<AddFriendFlow> createState() => _AddFriendFlowState();
}

class _AddFriendFlowState extends State<AddFriendFlow> {
  final TextEditingController _idController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();

  bool _isFormatValid = false;
  bool _userExists = false;
  bool _checking = false;

  void _onIdChanged(String value) async {
    final id = value.trim();
    final isValidFormat = RegExp(r'^\d{6}$').hasMatch(id);

    setState(() {
      _isFormatValid = isValidFormat;
      _userExists = false;
      _checking = isValidFormat;
    });

    if (isValidFormat) {
      final doc = await FirebaseFirestore.instance.collection('users').doc(id).get();
      setState(() {
        _userExists = doc.exists;
        _checking = false;
      });
    }
  }

  Future<void> _onFinish() async {
    final id = _idController.text.trim();
    final name = _nameController.text.trim();

    if (!_isFormatValid || !_userExists) return;

    // 💬 Отправляем приветственное сообщение и сохраняем имя
    await ChatService().sendMessage(
      senderId: widget.currentUserId,
      receiverId: id,
      text: '👋',
      receiverName: name.isNotEmpty ? name : null,
    );

    final entry = ChatEntry(
      id: id,
      name: name.isNotEmpty ? name : null,
    );

    Navigator.pop(context, entry);
  }

  Widget _buildInputField(
    TextEditingController controller, {
    required String hint,
    int? maxLength,
    TextInputType keyboardType = TextInputType.text,
    double letterSpacing = 0,
    void Function(String)? onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: controller,
        maxLength: maxLength,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: TextStyle(color: Colors.white, letterSpacing: letterSpacing),
        decoration: InputDecoration(
          border: InputBorder.none,
          counterText: '',
          hintText: hint,
          hintStyle: TextStyle(color: Colors.grey, letterSpacing: letterSpacing),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeText = const TextStyle(fontSize: 22, color: Colors.white);

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('Добавить друга'),
        backgroundColor: Colors.black,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Введите шестизначный ID друга', style: themeText),
                const SizedBox(height: 24),
                _buildInputField(
                  _idController,
                  hint: '— — — — — —',
                  maxLength: 6,
                  onChanged: _onIdChanged,
                  keyboardType: TextInputType.number,
                  letterSpacing: 3,
                ),
                const SizedBox(height: 10),
                if (_checking)
                  const Text('🔄 Проверка ID...', style: TextStyle(color: Colors.grey)),
                if (!_checking && _isFormatValid)
                  Text(
                    _userExists ? '✅ Профиль найден' : '❌ Такого пользователя не существует',
                    style: TextStyle(
                      color: _userExists ? Colors.green : Colors.redAccent,
                      fontSize: 16,
                    ),
                  ),
                if (!_isFormatValid)
                  const Text(
                    'Введите 6 цифр',
                    style: TextStyle(color: Colors.redAccent, fontSize: 16),
                  ),
                const SizedBox(height: 32),
                Text('Имя друга (необязательно)', style: themeText),
                const SizedBox(height: 24),
                _buildInputField(
                  _nameController,
                  hint: 'Например: Макс, Соня, Командир',
                  keyboardType: TextInputType.text,
                ),
              ],
            ),
            Positioned(
              bottom: 30,
              right: 30,
              child: GestureDetector(
                onTap: (_isFormatValid && _userExists) ? _onFinish : null,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: (_isFormatValid && _userExists)
                        ? Colors.black
                        : Colors.grey[800],
                    shape: BoxShape.rectangle,
                  ),
                  child: Icon(
                    Icons.arrow_forward,
                    color: (_isFormatValid && _userExists)
                        ? Colors.white
                        : Colors.grey,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class ChatScreen extends StatefulWidget {
  final ChatEntry chat;
  final String currentUserId;

  const ChatScreen({
    super.key,
    required this.chat,
    required this.currentUserId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    ChatService().sendMessage(
      senderId: widget.currentUserId,
      receiverId: widget.chat.id,
      text: text,
    );

    _controller.clear();
  }

  Widget _buildMessageBubble(Message msg) {
    final isMine = msg.senderId == widget.currentUserId;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: isMine ? Colors.green : Colors.red,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          msg.text,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.grey[850],
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Напиши сообщение...',
                hintStyle: TextStyle(color: Colors.grey),
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendMessage,
            child: Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(
                color: Colors.black,
                shape: BoxShape.rectangle,
              ),
              child: const Icon(Icons.send, color: Colors.white),
            ),
          )
        ],
      ),
    );
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: Text(widget.chat.name ?? widget.chat.id),
        backgroundColor: Colors.blue[800],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Message>>(
              stream: ChatService().getMessagesStream(
                widget.currentUserId,
                widget.chat.id,
              ),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final messages = snapshot.data!;

                // Прокрутка вниз после обновления
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _scrollToBottom();
                });

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (_, i) => _buildMessageBubble(messages[i]),
                );
              },
            ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }
}