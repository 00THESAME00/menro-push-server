import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';  // ← этот импорт можно оставить, он не мешает
import 'models/message.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';


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

  static Future<void> initFirebaseMessaging({required String userId}) async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();

    final token = await messaging.getToken();
    print("📲 Получен FCM токен: $token");

    if (token == null) {
      print("⚠️ FCM токен не получен");
      return;
    }

    final docRef = FirebaseFirestore.instance.collection('users').doc(userId);
    final snapshot = await docRef.get();
    final savedToken = snapshot.data()?['fcmToken'];

    if (savedToken != token) {
      await docRef.set({'fcmToken': token}, SetOptions(merge: true));
      print("✅ FCM токен обновлён в Firestore");
    } else {
      print("👌 FCM токен актуален, обновление не требуется");
    }

    messaging.onTokenRefresh.listen((newToken) async {
      await docRef.set({'fcmToken': newToken}, SetOptions(merge: true));
      print("🔄 FCM токен обновлён через onTokenRefresh: $newToken");
    });

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
  runApp(const MyApp());
}

class VersionBlocker {
  static bool _shouldBlock = false;
  static String _updateUrl = '';
  static OverlayEntry? _overlay;

  static Future<void> checkAndBlock(BuildContext context) async {
    if (_shouldBlock) {
      debugPrint('[VersionBlocker] Уже заблокировано, показываем overlay');
      _showOverlay(context);
      return;
    }

    try {
      final remote = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('version')
          .get();

      final minVersion = remote['min_required_version'] as String?;
      final updateUrl = remote['update_url'] as String?;

      debugPrint('[VersionBlocker] min_required_version из Firebase: $minVersion');
      debugPrint('[VersionBlocker] update_url из Firebase: $updateUrl');

      if (minVersion == null || updateUrl == null) {
        debugPrint('[VersionBlocker] minVersion или updateUrl == null, выходим');
        return;
      }

      final info = await PackageInfo.fromPlatform();
      final currentVersion = info.version;

      debugPrint('[VersionBlocker] Текущая версия приложения: $currentVersion');

      final outdated = _isOutdated(currentVersion, minVersion);

      debugPrint('[VersionBlocker] Сравнение версий: $currentVersion vs $minVersion → outdated = $outdated');

      if (outdated) {
        _shouldBlock = true;
        _updateUrl = updateUrl;
        debugPrint('[VersionBlocker] Версия устарела, показываем overlay');
        _showOverlay(context);
      } else {
        debugPrint('[VersionBlocker] Версия актуальна, ничего не делаем');
      }
    } catch (e, stack) {
      debugPrint('[VersionBlocker] Ошибка при проверке версии: $e');
      debugPrint(stack.toString());
    }
  }

  static bool _isOutdated(String current, String min) {
    final c = current.split('.').map(int.parse).toList();
    final m = min.split('.').map(int.parse).toList();

    for (int i = 0; i < m.length; i++) {
      if (c.length <= i || c[i] < m[i]) return true;
      if (c[i] > m[i]) return false;
    }

    return false;
  }

  static void _showOverlay(BuildContext context) {
    if (_overlay != null) {
      debugPrint('[VersionBlocker] Overlay уже показан');
      return;
    }

    debugPrint('[VersionBlocker] Вставляем overlay');

    final controller = ValueNotifier<double>(0.8);

    _overlay = OverlayEntry(
      builder: (_) => Stack(
        children: [
          AbsorbPointer(absorbing: true, child: Container(color: Colors.black.withOpacity(0.1))),
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.only(top: MediaQuery.of(context).size.height * 0.25),
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, child) => Transform.scale(
                  scale: controller.value,
                  child: child,
                ),
                child: Semantics(
                  container: true,
                  excludeSemantics: true,
                  child: Container(
                    width: 330,
                    height: 227,
                    decoration: BoxDecoration(
                      color: const Color(0xFF171719),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFFC5C6D9),
                        width: 2,
                        strokeAlign: BorderSide.strokeAlignOutside,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Обновление',
                          style: TextStyle(
                            fontSize: 25,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFEFF0FF),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Вышла новая версия приложения.\nОбновите, чтобы продолжить.',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.normal,
                            color: Color(0xFFEFF0FF),
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                          softWrap: true,
                        ),
                        const SizedBox(height: 20),
                        Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(13),
                          child: InkWell(
                            onTap: () async {
                              try {
                                final uri = Uri.parse(_updateUrl);
                                final canLaunch = await canLaunchUrl(uri);
                                debugPrint('[VersionBlocker] canLaunch = $canLaunch');

                                if (canLaunch) {
                                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                                } else {
                                  debugPrint('[VersionBlocker] Не удалось открыть ссылку: $_updateUrl');
                                }
                              } catch (e) {
                                debugPrint('[VersionBlocker] Ошибка при открытии ссылки: $e');
                              }
                            },
                            borderRadius: BorderRadius.circular(13),
                            splashColor: Colors.white.withOpacity(0.3),
                            child: Ink(
                              width: 263,
                              height: 56,
                              decoration: BoxDecoration(
                                color: const Color(0xFF4C43EF),
                                borderRadius: BorderRadius.circular(13),
                              ),
                              child: const Center(
                                child: Text(
                                  'Скачать',
                                  style: TextStyle(
                                    fontSize: 25,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFFEFF0FF),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          )
        ],
      ),
    );

    Overlay.of(context, rootOverlay: true).insert(_overlay!);

    Future.delayed(const Duration(milliseconds: 50), () {
      controller.value = 1.0;
    });
  }
}

// 1. Welcome Screen

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
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
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      VersionBlocker.checkAndBlock(context); // ✅ Проверка версии
    });
  }

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

    final sessionId = const Uuid().v4();
    debugPrint('🆔 Сгенерирован sessionId: $sessionId');

    if (snapshot.exists) {
      final stored = snapshot.data();

      if (stored?['access'] == false) {
        setState(() {
          _statusMessage = '🚫 Этот профиль заблокирован';
          _isLoading = false;
        });
        return;
      }

      if (stored?['password'] != password) {
        setState(() {
          _statusMessage = '❌ Неверный пароль';
          _isLoading = false;
        });
        return;
      }

      if (!stored!.containsKey('access')) {
        await docRef.update({'access': true});
        debugPrint('🛠️ Добавлено поле access: true для старого профиля');
      }

      await docRef.update({'sessionId': sessionId});
      debugPrint('🔄 Обновлён sessionId для существующего пользователя');
    } else {
      await docRef.set({
        'password': password,
        'sessionId': sessionId,
        'access': true,
      });
      debugPrint('✅ Создан новый профиль с sessionId');
      setState(() {
        _statusMessage = '✅ Профиль создан';
      });
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('userId', id);
    await prefs.setString('sessionId', sessionId);
    debugPrint('💾 sessionId сохранён локально');

    await Global.initFirebaseMessaging(userId: id);

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
                  obscureText: !_showPassword,
                  isPassword: true,
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
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
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
    bool isPassword = false,
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
          suffixIcon: isPassword
              ? GestureDetector(
                  onTapDown: (_) => setState(() => _showPassword = true),
                  onTapUp: (_) => setState(() => _showPassword = false),
                  onTapCancel: () => setState(() => _showPassword = false),
                  child: const Icon(Icons.visibility_outlined, color: Colors.white38),
                )
              : null,
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

class _ChatListScreenState extends State<ChatListScreen> with TickerProviderStateMixin {
  late final Stream<List<ChatEntry>> _chatStream;
  Timer? _longPressTimer;
  ChatEntry? _selectedChat;
  bool _isSubMenuOpen = false;

  final String? avatarUrl = null; // TODO: заменить на реальные данные

  @override
  void initState() {
    super.initState();
    _chatStream = ChatService().getUserChats(widget.currentUserId);
    _listenToSession(); // 🔐 контроль сессии

    WidgetsBinding.instance.addPostFrameCallback((_) {
      VersionBlocker.checkAndBlock(context); // ✅ Проверка версии
    });
  }

  void _openChat(ChatEntry chat) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(chat: chat, currentUserId: widget.currentUserId),
      ),
    );
  }

  void _listenToSession() async {
    final prefs = await SharedPreferences.getInstance();
    final localSessionId = prefs.getString('sessionId');
    final userId = widget.currentUserId;

    if (localSessionId == null) {
      debugPrint('⚠️ sessionId не найден локально');
      return;
    }

    FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .snapshots()
        .listen((snapshot) {
      final remoteSessionId = snapshot.data()?['sessionId'];
      if (remoteSessionId == null) {
        debugPrint('⚠️ sessionId отсутствует в Firestore');
        return;
      }

      if (remoteSessionId != localSessionId) {
        debugPrint('🚫 Сессия перехвачена другим устройством');
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const WelcomeScreen()),
          (_) => false,
        );
      } else {
        debugPrint('✅ sessionId совпадает, всё ок');
      }
    });
  }

  void _addNewChat() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddFriendFlow(currentUserId: widget.currentUserId)),
    );
    if (result is ChatEntry) {
      _openChat(result);
    }
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
    await ChatService().clearChatMessages(widget.currentUserId, _selectedChat!.id);
    setState(() {
      _selectedChat = null;
      _isSubMenuOpen = false;
    });
  }

  void _deleteChat() async {
    if (_selectedChat == null) return;
    await ChatService().deleteChatLocally(widget.currentUserId, _selectedChat!.id);
    setState(() {
      _selectedChat = null;
      _isSubMenuOpen = false;
    });
  }

  void _renameChat() async {
    final chatToEdit = _selectedChat;
    setState(() {
      _selectedChat = null;
      _isSubMenuOpen = false;
    });

    if (chatToEdit != null) {
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RenameChatScreen(
            currentUserId: widget.currentUserId,
            peerId: chatToEdit.id,
            currentName: chatToEdit.name,
          ),
        ),
      );
      if (result is String) {
        print("✅ Имя обновлено: $result");
      }
    }
  }

  void _toggleSubMenu() => setState(() => _isSubMenuOpen = !_isSubMenuOpen);

  void _closeAll() => setState(() {
    _selectedChat = null;
    _isSubMenuOpen = false;
  });

  Widget buildAvatarButton() {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserProfileScreen(userId: widget.currentUserId),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Colors.grey.shade700, Colors.black],
          ),
        ),
        child: CircleAvatar(
          radius: 18,
//ч1
          backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
          backgroundColor: Colors.grey[800],
          child: avatarUrl == null
              ? const Icon(Icons.person, color: Colors.white)
              : null,
        ),
      ),
    );
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
                    _selectedChat != null
                        ? AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            child: IconButton(
                              key: ValueKey(_selectedChat != null),
                              icon: const Icon(Icons.close, color: Colors.white),
                              onPressed: _closeAll,
                            ),
                          )
                        : buildAvatarButton(),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Чаты (${widget.currentUserId})',
                        style: const TextStyle(color: Colors.white, fontSize: 18),
                      ),
                    ),
                    if (_selectedChat != null)
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, color: Colors.white),
                            onPressed: _renameChat,
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.white),
                            onPressed: _deleteChat,
                          ),
                          IconButton(
                            icon: const Icon(Icons.more_vert, color: Colors.white),
                            onPressed: _toggleSubMenu,
                          ),
                        ],
                      ),
                  ],
                ),
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
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                TextButton.icon(
                                  onPressed: _clearChat,
                                  icon: const Icon(Icons.cleaning_services_outlined, color: Colors.white),
                                  label: const Text('Очистить чат', style: TextStyle(color: Colors.white)),
                                ),
                                TextButton.icon(
                                  onPressed: null,
                                  icon: const Icon(Icons.hourglass_bottom_outlined, color: Colors.white38),
                                  label: const Text('Coming soon...', style: TextStyle(color: Colors.white38)),
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
                child: Text('У тебя пока нет чатов', style: TextStyle(color: Colors.white70)),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              itemCount: chats.length,
              separatorBuilder: (_, __) => const SizedBox(height: 14),
              itemBuilder: (_, index) {
                final chat = chats[index];
                final label = chat.name?.isNotEmpty == true ? chat.name! : chat.id;
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
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 18)),
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


class UserProfileScreen extends StatefulWidget {
  final String userId;
  const UserProfileScreen({super.key, required this.userId});

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _menuIconKey = GlobalKey();
  bool showTopIcons = true;

  String? avatarUrl;
  String? userName;
  String? userStatus;
  String? aboutMe;
  String version = '0.55.0';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final shouldShow = _scrollController.offset <= 40;
      if (shouldShow != showTopIcons) {
        setState(() => showTopIcons = shouldShow);
      }
    });
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.userId)
        .get();

    if (!doc.exists) {
      debugPrint('❌ Документ пользователя не найден');
      return;
    }

    final data = doc.data();
    debugPrint('📥 Данные из Firestore: $data');

    if (!mounted) return;
    setState(() {
      avatarUrl = data?['avatarUrl'];
      debugPrint('📷 avatarUrl из Firestore: $avatarUrl');

      userName   = data?['name'];
      userStatus = data?['status'];
      aboutMe    = data?['aboutMe'];
      version    = data?['version'] ?? version;
    });
  }

  Future<String> _uploadAvatar(File file) async {
  final ref = FirebaseStorage.instance
      .ref('avatars/${widget.userId}.jpg');

  debugPrint('📤 Загружаем в: avatars/${widget.userId}.jpg');

  try {
    final bytes = await file.readAsBytes();
    await ref.putData(bytes);
    final url = await ref.getDownloadURL();
    debugPrint('🔗 Получена ссылка: $url');
    return url;
  } catch (e) {
    debugPrint('❌ Ошибка загрузки файла: $e');
    rethrow;
  }
}

// 👇 Вставь сюда:
Future<void> _handleAvatarUpload() async {
  try {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) {
      debugPrint('📂 Фото не выбрано');
      return;
    }

    final file = File(picked.path);
    debugPrint('📁 Путь к файлу: ${file.path}');

    final downloadUrl = await _uploadAvatar(file);
    debugPrint('📸 Ссылка на загруженное фото: $downloadUrl');

    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.userId)
        .update({'avatarUrl': downloadUrl});
    debugPrint('✅ avatarUrl сохранён в Firestore');

    if (!mounted) return;
    setState(() => avatarUrl = downloadUrl);
    debugPrint('🔄 avatarUrl обновлён в UI');

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Фото успешно загружено')),
    );
  } catch (e, stack) {
    debugPrint('❌ Ошибка загрузки: $e');
    debugPrint('📛 Стек: $stack');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Ошибка загрузки фото: $e')),
    );
  }
}


  void _showTopMenu(BuildContext context) {
  final overlay = Overlay.of(context);
  final renderBox = _menuIconKey.currentContext?.findRenderObject() as RenderBox?;
  if (renderBox == null) return;

  final offset = renderBox.localToGlobal(Offset.zero);

  late OverlayEntry entry;

  entry = OverlayEntry(
    builder: (context) => GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => entry.remove(), // ❗ Закрытие при тапе вне меню
      child: Stack(
        children: [
          Positioned(
            top: offset.dy + 40,
            right: 16,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 220,
                decoration: BoxDecoration(
                  color: const Color(0xFF343434),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _menuItem('📷 Выбрать фотографию', () async {
                      entry.remove();
                      await _handleAvatarUpload();
                    }),
                    _menuItem('🗑️ Удалить фотографию', () async {
                      entry.remove();

                      try {
                        await FirebaseFirestore.instance
                            .collection('users')
                            .doc(widget.userId)
                            .update({'avatarUrl': FieldValue.delete()});

                        if (!mounted) return;
                        setState(() => avatarUrl = null);

                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Ссылка на фото удалена')),
                        );
                      } catch (e) {
                        debugPrint('❌ Ошибка удаления avatarUrl: $e');
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Ошибка удаления фото: $e')),
                        );
                      }
                    }),
                    _menuItem('🚪 Выход', () {
                      entry.remove();
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => EnterYourIdScreen()),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  overlay.insert(entry);
}

  Widget _menuItem(String text, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Text(text, style: const TextStyle(color: Colors.white, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayName =
        (userName?.isNotEmpty == true) ? userName! : widget.userId;

    return Scaffold(
      backgroundColor: Colors.grey[900],
      body: SafeArea(
        child: Stack(
          children: [
            // 1) Контент экрана — самый глубокий слой
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 72),
                    // Аватар
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Colors.grey.shade700, Colors.black],
                        ),
                      ),
                      padding: const EdgeInsets.all(2),
                      child: CircleAvatar(
                        radius: 48,
                        backgroundImage: avatarUrl != null
                            ? NetworkImage(avatarUrl!)
                            : null,
                        backgroundColor: Colors.grey[800],
                        child: avatarUrl == null
                            ? const Icon(Icons.person,
                                color: Colors.white, size: 36)
                            : null,
                      ),
                    ),
                    const SizedBox(height: 12),
//ч1                    
                    // Имя
                    Text(
                      displayName,
                      style:
                          const TextStyle(fontSize: 22, color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    // ID + копирование
                    GestureDetector(
                      onTap: () {
                        Clipboard.setData(
                            ClipboardData(text: widget.userId));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('ID скопирован')),
                        );
                      },
                      child: Text('ID: ${widget.userId}',
                          style: const TextStyle(color: Colors.white54)),
                    ),
                    const SizedBox(height: 6),
                    // Статус
                    if (userStatus?.isNotEmpty == true)
                      Text(userStatus!,
                          style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 18),
                    const Divider(),
                    const SizedBox(height: 12),
                    const Text('Обо мне',
                        style:
                            TextStyle(color: Colors.white, fontSize: 16)),
                    const SizedBox(height: 8),
                    Text(
                      aboutMe?.isNotEmpty == true ? aboutMe! : 'Здесь что-то будет',
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 8),
                    const Text('Настройки',
                        style:
                            TextStyle(color: Colors.white, fontSize: 16)),
                    const SizedBox(height: 8),
                    // Настройки
                    ListTile(
                      leading:
                          const Icon(Icons.lock_outline, color: Colors.white),
                      title: const Text('Конфиденциальность',
                          style: TextStyle(color: Colors.white)),
                      onTap: () {},
                    ),
                    ListTile(
                      leading: const Icon(Icons.notifications_outlined,
                          color: Colors.white),
                      title: const Text('Уведомления',
                          style: TextStyle(color: Colors.white)),
                      onTap: () {},
                    ),
                    ListTile(
                      leading:
                          const Icon(Icons.person_outline, color: Colors.white),
                      title: const Text('Кастомизация',
                          style: TextStyle(color: Colors.white)),
                      onTap: () {},
                    ),
                    ListTile(
                      leading:
                          const Icon(Icons.language_outlined, color: Colors.white),
                      title: const Text('Язык',
                          style: TextStyle(color: Colors.white)),
                      onTap: () {},
                    ),
                    ListTile(
                      leading: const Icon(Icons.help_outline, color: Colors.white),
                      title: const Text('Помощь',
                          style: TextStyle(color: Colors.white)),
                      onTap: () {},
                    ),
                    const Divider(),
                    const SizedBox(height: 8),
                    Text('Menro Beta $version',
                        style: const TextStyle(color: Colors.white30)),
                    const SizedBox(height: 6),
                    const Text('Made with 💀 in Menro',
                        style: TextStyle(color: Colors.white30)),
                  ],
                ),
              ),
//ч2
            ),
            // 2) Верхние кнопки «меню» и «редактировать»
            AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: showTopIcons ? 1 : 0,
              child: IgnorePointer(
                ignoring: !showTopIcons,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, top: 12),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Builder(
                          builder: (context) => IconButton(
                            key: _menuIconKey,
                            icon: const Icon(Icons.more_vert, color: Colors.white),
                            onPressed: () => _showTopMenu(context),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit, color: Colors.white),
                          onPressed: () async {
                            final updated = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => EditProfileScreen(userId: widget.userId),
                              ),
                            );
                            if (updated == true) {
                              _loadUserData(); // повторная загрузка
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),


            // 3) Кнопка «назад» — самый верхний слой
            Positioned(
              top: 12,
              left: 12,
              child: Material(
                color: Colors.transparent,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new,
                      color: Colors.white),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ChatListScreen(currentUserId: widget.userId),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
//ч3

class EditProfileScreen extends StatefulWidget {
  final String userId;

  const EditProfileScreen({super.key, required this.userId});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController aboutController = TextEditingController();
  String avatarUrl = 'https://example.com/avatar.jpg';

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final docRef = FirebaseFirestore.instance.collection('users').doc(widget.userId);
    print('📥 Загружаем данные профиля из Firestore users/${widget.userId}');

    try {
      final snapshot = await docRef.get();
      final data = snapshot.data();
      if (data != null) {
        nameController.text = data['name'] ?? '';
        aboutController.text = data['aboutMe'] ?? '';
        print('📋 Имя из Firestore: "${nameController.text}"');
        print('📋 О себе из Firestore: "${aboutController.text}"');
      } else {
        print('🛑 Документ не найден — поля останутся пустыми');
      }
    } catch (error) {
      print('❌ Ошибка при загрузке данных: $error');
    }
  }

  Future<void> _saveProfile() async {
    final uid = widget.userId;
    print('🧾 Получен uid из FirebaseAuth: $uid');
    print('🔗 widget.userId: ${widget.userId}');


    final name = nameController.text.trim();
    final about = aboutController.text.trim();

    print('📋 Введено имя: "$name"');
    print('📋 Введено описание: "$about"');

    final updates = <String, dynamic>{};
    if (name.isNotEmpty) updates['name'] = name;
    if (about.isNotEmpty) updates['aboutMe'] = about;

    if (updates.isEmpty) {
      print('⚠️ Ни одно поле не заполнено — показываем SnackBar');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите хотя бы одно поле')),
      );
      return;
}

    final docRef = FirebaseFirestore.instance.collection('users').doc(uid);
    print('🔍 Проверяем существование документа users/$uid');

    try {
      final docSnapshot = await docRef.get();
      if (!docSnapshot.exists) {
        print('🆕 Документ не существует — создаём новый');
        updates['createdAt'] = FieldValue.serverTimestamp();
        await docRef.set(updates);
        print('✅ Профиль создан');
      } else {
        print('✏️ Документ существует — обновляем');
        final oldData = docSnapshot.data() ?? {};
        final updates = <String, dynamic>{};

        if (name.isNotEmpty && name != oldData['name']) {
          updates['name'] = name;
        }
        if (about.isNotEmpty && about != oldData['aboutMe']) {
          updates['aboutMe'] = about;
        }

        if (updates.isEmpty) {
          print('🛑 Нет изменений — ничего не отправляем в Firestore');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Нет изменений')),
          );
          return;
        }

        await docRef.update(updates);
        print('✅ Профиль обновлён');
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Профиль сохранён')),
      );
      Navigator.pop(context, true);
    } catch (error) {
      print('❌ Ошибка Firestore: $error');
      print('🧠 Тип ошибки: ${error.runtimeType}');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: ${error.toString()}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarHeight = MediaQuery.of(context).padding.top;
    final double bottomInset = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF212121),
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 120, bottom: 80),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
//граница1
                    SizedBox(
                      width: 180,
                      height: 110,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Positioned.fill(
                            child: Align(
                              alignment: Alignment.center,
                              child: CircleAvatar(
                                radius: 50,
                                backgroundColor: Colors.grey,
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: -16,
                            right: -60,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF353537),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                minimumSize: const Size(0, 0),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                elevation: 0,
                              ),
                              onPressed: () {
                                print('Изменить аватар');
                              },
                              child: const Text(
                                'Изменить',
                                style: TextStyle(color: Colors.white, fontSize: 14),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: Divider(color: Color(0xFF474747), thickness: 1, height: 24),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: 320,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onLongPress: () {
                                Clipboard.setData(ClipboardData(text: widget.userId));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('ID скопирован'), duration: Duration(seconds: 1)),
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade600),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    const Text('Код:', style: TextStyle(color: Colors.grey)),
                                    const SizedBox(width: 8),
                                    Text(widget.userId, style: const TextStyle(fontWeight: FontWeight.bold)),
                                    const Spacer(),
                                    const Icon(Icons.copy, size: 18, color: Colors.grey),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text('Ваш личный код', style: TextStyle(color: Colors.grey, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: 320, 
//граница2
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: nameController,
                            decoration: const InputDecoration(
                              labelText: 'Имя',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text('Имя пользователя', style: TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: 320,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: aboutController,
                            maxLines: 4,
                            maxLength: 100,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Обо мне',
                              border: OutlineInputBorder(),
                              counterText: '',
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              const Text('Расскажите о себе', style: TextStyle(color: Colors.grey, fontSize: 12)),
                              Text('${aboutController.text.length}/100',
                                style: const TextStyle(color: Colors.grey, fontSize: 12)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: statusBarHeight + 12,
              left: 12,
              child: Material(
                color: Colors.transparent,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 24),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
            Positioned(
              bottom: bottomInset,
              left: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF353537),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                    elevation: 0,
                  ),
                  onPressed: _saveProfile,
                  child: const Text('Сохранить'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}  //граница3
// Изменить чат

class RenameChatScreen extends StatefulWidget {
  final String currentUserId;
  final String peerId;
  final String? currentName;

  const RenameChatScreen({
    super.key,
    required this.currentUserId,
    required this.peerId,
    this.currentName,
  });

  @override
  State<RenameChatScreen> createState() => _RenameChatScreenState();
}

class _RenameChatScreenState extends State<RenameChatScreen> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentName ?? '');
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();

    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.currentUserId)
        .collection('chatList')
        .doc(widget.peerId)
        .update({'name': name});

    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.peerId)
        .collection('chatList')
        .doc(widget.currentUserId)
        .update({'name': widget.currentName ?? widget.currentUserId});

    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Изменить', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Код друга', style: TextStyle(fontSize: 20, color: Colors.white)),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(widget.peerId, style: const TextStyle(color: Colors.white70, fontSize: 18)),
                ),
                const SizedBox(height: 6),
                const Text('🔒 Код друга (нельзя изменить)', style: TextStyle(color: Colors.grey, fontSize: 14)),

                const SizedBox(height: 32),
                const Text('Имя друга', style: TextStyle(fontSize: 20, color: Colors.white)),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _nameController,
                    maxLength: 15,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      counterText: '',
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
                onTap: _saveName,
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