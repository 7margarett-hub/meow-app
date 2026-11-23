import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const bg = Color(0xFF111218);
const panel = Color(0xFF1C1D28);
const purple = Color(0xFF8B5CF6);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const apiKey = String.fromEnvironment('FB_API_KEY');
  const appId = String.fromEnvironment('FB_APP_ID');
  const senderId = String.fromEnvironment('FB_SENDER_ID');
  const projectId = String.fromEnvironment('FB_PROJECT_ID');
  if ([apiKey, appId, senderId, projectId].any((v) => v.isEmpty)) {
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Configure o Firebase no GitHub Actions.')))));
    return;
  }
  try {
    await Firebase.initializeApp(options: const FirebaseOptions(
      apiKey: apiKey, appId: appId, messagingSenderId: senderId, projectId: projectId,
    ));
    runApp(const MeowApp());
  } catch (e) {
    runApp(MaterialApp(home: Scaffold(body: Center(child: Text('Erro ao iniciar Firebase: $e')))));
  }
}

String cleanName(String value) => value.trim().toLowerCase();
String loginEmail(String name) => '${cleanName(name)}@users.meow.invalid';

class MeowApp extends StatelessWidget {
  const MeowApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Meow Social', debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(seedColor: purple, brightness: Brightness.dark),
      appBarTheme: const AppBarTheme(backgroundColor: panel),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: panel,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    home: StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        if (!snap.hasData && snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return snap.data == null ? const LoginPage() : const SocialHome();
      },
    ),
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final username = TextEditingController();
  final password = TextEditingController();
  bool register = false, loading = false;
  String? error;

  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final name = cleanName(username.text);
    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(name)) {
      setState(() => error = 'Use 3 a 20 letras minúsculas, números ou _.');
      return;
    }
    if (password.text.length < 8) {
      setState(() => error = 'A senha precisa ter pelo menos 8 caracteres.');
      return;
    }
    setState(() { loading = true; error = null; });
    try {
      if (register) {
        final credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: loginEmail(name), password: password.text,
        );
        await FirebaseFirestore.instance.collection('users').doc(credential.user!.uid).set({
          'username': name, 'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: loginEmail(name), password: password.text,
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => error = e.code == 'email-already-in-use'
          ? 'Esse nome já está em uso.' : 'Falha no login: ${e.code}');
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: SafeArea(child: Center(
    child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.pets, size: 70, color: purple),
        const SizedBox(height: 12),
        Text(register ? 'Criar conta Meow' : 'Entrar no Meow',
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const SizedBox(height: 24),
        TextField(controller: username, autocorrect: false,
          decoration: const InputDecoration(labelText: 'Usuário')),
        const SizedBox(height: 12),
        TextField(controller: password, obscureText: true,
          decoration: const InputDecoration(labelText: 'Senha')),
        if (error != null) Padding(padding: const EdgeInsets.all(10),
          child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
        const SizedBox(height: 16),
        FilledButton(onPressed: loading ? null : submit,
          child: Text(loading ? 'Aguarde...' : register ? 'Criar conta' : 'Entrar')),
        TextButton(onPressed: () => setState(() { register = !register; error = null; }),
          child: Text(register ? 'Já tenho conta' : 'Criar conta')),
        const Text('O aplicativo usa um identificador interno no Firebase. Você não precisa digitar e-mail.',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12)),
      ]),
    )),
  )));
}

class SocialHome extends StatefulWidget {
  const SocialHome({super.key});
  @override
  State<SocialHome> createState() => _SocialHomeState();
}

class _SocialHomeState extends State<SocialHome> {
  final db = FirebaseFirestore.instance;
  String? serverId, channelId;
  int tab = 0;
  String get uid => FirebaseAuth.instance.currentUser!.uid;

  void notice(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<String?> prompt(String title, String hint, {int maxLength = 40}) async {
    final controller = TextEditingController();
    return showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true, maxLength: maxLength,
        decoration: InputDecoration(hintText: hint)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Confirmar')),
      ],
    ));
  }

  Future<void> createServer() async {
    final name = await prompt('Criar servidor', 'Nome do servidor');
    if (name == null || name.isEmpty) return;
    try {
      final server = await db.collection('servers').add({
        'name': name, 'ownerId': uid, 'members': [uid],
        'createdAt': FieldValue.serverTimestamp(),
      });
      await server.collection('channels').add({
        'name': 'geral', 'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() { serverId = server.id; channelId = null; tab = 0; });
    } catch (e) { notice('Não foi possível criar: $e'); }
  }

  Future<void> createChannel() async {
    if (serverId == null) return;
    final name = await prompt('Criar canal', 'Nome do canal');
    if (name == null || name.isEmpty) return;
    try {
      await db.collection('servers').doc(serverId).collection('channels').add({
        'name': name, 'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) { notice('Não foi possível criar canal: $e'); }
  }

  String newCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(10, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }

  Future<void> createInvite() async {
    if (serverId == null) return;
    try {
      // Matches the Firestore invite schema: serverId, createdBy, createdAt.
      final code = newCode();
      await db.collection('invites').doc(code).set({
        'serverId': serverId,
        'createdBy': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('Convite do Meow'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Compartilhe este código com um amigo:'),
          const SizedBox(height: 12),
          SelectableText(code, style: const TextStyle(
            fontSize: 25, fontWeight: FontWeight.bold, letterSpacing: 2)),
        ]),
        actions: [
          TextButton(onPressed: () {
            Clipboard.setData(ClipboardData(text: code));
            Navigator.pop(ctx);
            notice('Código copiado!');
          }, child: const Text('Copiar')),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fechar')),
        ],
      ));
    } catch (e) { notice('Não foi possível gerar convite: $e'); }
  }

  Future<void> joinInvite() async {
    final input = await prompt('Entrar com convite', 'Código de 10 caracteres', maxLength: 20);
    if (input == null || input.isEmpty) return;
    final code = input.trim().toUpperCase();
    if (!RegExp(r'^[A-HJ-NP-Z2-9]{10}$').hasMatch(code)) {
      notice('Digite um código válido de 10 caracteres.');
      return;
    }
    try {
      final invite = await db.collection('invites').doc(code).get();
      final data = invite.data();
      if (data == null || data['serverId'] is! String) {
        notice('Convite inválido.');
        return;
      }
      final id = data['serverId'] as String;
      final batch = db.batch();
      final proofRef = db.collection('joinProofs').doc(id).collection('users').doc(uid);
      final serverRef = db.collection('servers').doc(id);
      batch.set(proofRef, {'serverId': id, 'code': code});
      batch.update(serverRef, {'members': FieldValue.arrayUnion([uid])});
      await batch.commit();
      if (mounted) setState(() { serverId = id; channelId = null; tab = 0; });
      notice('Você entrou no servidor!');
    } catch (e) {
      notice('Não foi possível entrar. Confira as regras do Firebase: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('🐱 Meow Social'), actions: [
      IconButton(tooltip: 'Sair', onPressed: () => FirebaseAuth.instance.signOut(),
        icon: const Icon(Icons.logout)),
    ]),
    body: Column(children: [
      Expanded(child: tab == 1 ? FriendsPage(uid: uid) : tab == 2 ? ProfilePage(uid: uid) : Row(children: [
        SizedBox(width: 72, child: ColoredBox(color: const Color(0xFF0B0C11), child: Column(children: [
          IconButton(tooltip: 'Criar servidor', onPressed: createServer,
            icon: const Icon(Icons.add_circle, color: purple)),
          IconButton(tooltip: 'Entrar com convite', onPressed: joinInvite,
            icon: const Icon(Icons.group_add)),
          Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: db.collection('servers').where('members', arrayContains: uid).snapshots(),
            builder: (context, snap) {
              if (snap.hasError) return const Center(child: Icon(Icons.error_outline));
              return ListView(children: [for (final doc in snap.data?.docs ?? [])
                Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: CircleAvatar(
                  backgroundColor: serverId == doc.id ? purple : panel,
                  child: IconButton(tooltip: doc.data()['name']?.toString() ?? 'Servidor',
                    onPressed: () => setState(() { serverId = doc.id; channelId = null; }),
                    icon: Text((doc.data()['name']?.toString().isNotEmpty == true
                      ? doc.data()['name'].toString() : 'S').substring(0, 1).toUpperCase(),
                      style: const TextStyle(color: Colors.white))),
                )),
              ]);
            },
          )),
        ]))),
        Expanded(child: serverId == null
          ? const Center(child: Text('Crie um servidor ou entre com um convite.'))
          : Column(children: [
            Container(color: panel, child: Row(children: [
              const Expanded(child: Padding(padding: EdgeInsets.all(12),
                child: Text('Canais', style: TextStyle(fontWeight: FontWeight.bold)))),
              IconButton(tooltip: 'Novo canal', onPressed: createChannel,
                icon: const Icon(Icons.add)),
              IconButton(tooltip: 'Gerar convite', onPressed: createInvite,
                icon: const Icon(Icons.share)),
            ])),
            SizedBox(height: 58, child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db.collection('servers').doc(serverId).collection('channels').snapshots(),
              builder: (context, snap) {
                if (snap.hasError) return const Center(child: Text('Erro nos canais'));
                final docs = snap.data?.docs ?? [];
                final active = docs.any((d) => d.id == channelId)
                  ? channelId : (docs.isEmpty ? null : docs.first.id);
                if (active != channelId) WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && channelId != active) setState(() => channelId = active);
                });
                return ListView(scrollDirection: Axis.horizontal, children: [for (final doc in docs)
                  Padding(padding: const EdgeInsets.all(5), child: ChoiceChip(
                    label: Text('# ${doc.data()['name'] ?? 'canal'}'), selected: active == doc.id,
                    onSelected: (_) => setState(() => channelId = doc.id),
                  )),
                ]);
              },
            )),
            Expanded(child: channelId == null
              ? const Center(child: Text('Selecione um canal'))
              : ChatPage(key: ValueKey('$serverId/$channelId'),
                  serverId: serverId!, channelId: channelId!, uid: uid)),
          ])),
      ])),
      NavigationBar(height: 70, selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i), destinations: const [
          NavigationDestination(icon: Icon(Icons.tag), label: 'Canais'),
          NavigationDestination(icon: Icon(Icons.people), label: 'Amigos'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Perfil'),
        ]),
    ]),
  );
}

class ChatPage extends StatefulWidget {
  final String serverId, channelId, uid;
  const ChatPage({super.key, required this.serverId, required this.channelId, required this.uid});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController();
  bool sending = false;
  @override
  void dispose() { input.dispose(); super.dispose(); }
  CollectionReference<Map<String, dynamic>> get messages => FirebaseFirestore.instance
    .collection('servers').doc(widget.serverId)
    .collection('channels').doc(widget.channelId).collection('messages');

  Future<void> send() async {
    final value = input.text.trim();
    if (value.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      final user = await FirebaseFirestore.instance.collection('users').doc(widget.uid).get();
      await messages.add({
        'text': value, 'authorId': widget.uid,
        'author': user.data()?['username'] ?? 'Usuário',
        'createdAt': FieldValue.serverTimestamp(),
      });
      input.clear();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao enviar: $e')));
    }
    if (mounted) setState(() => sending = false);
  }

  @override
  Widget build(BuildContext context) => Column(children: [
    Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: messages.orderBy('createdAt', descending: true).limit(100).snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Erro ao carregar: ${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final docs = snap.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('Diga oi! 👋'));
        return ListView.builder(reverse: true, padding: const EdgeInsets.all(12),
          itemCount: docs.length, itemBuilder: (context, i) {
            final data = docs[i].data();
            final author = data['author']?.toString() ?? 'Usuário';
            return ListTile(
              leading: CircleAvatar(backgroundColor: purple,
                child: Text(author.isEmpty ? '?' : author[0].toUpperCase())),
              title: Text(author, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              subtitle: Text(data['text']?.toString() ?? '',
                style: const TextStyle(fontSize: 15, color: Colors.white)),
            );
          });
      },
    )),
    SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
      Expanded(child: TextField(controller: input, minLines: 1, maxLines: 4, maxLength: 2000,
        decoration: const InputDecoration(hintText: 'Mensagem', counterText: ''),
        onSubmitted: (_) => send())),
      IconButton(onPressed: sending ? null : send, icon: const Icon(Icons.send, color: purple)),
    ]))),
  ]);
}

class FriendsPage extends StatefulWidget {
  final String uid;
  const FriendsPage({super.key, required this.uid});
  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  final username = TextEditingController();
  String? status;
  @override
  void dispose() { username.dispose(); super.dispose(); }

  Future<void> addFriend() async {
    final name = cleanName(username.text);
    if (name.isEmpty) return;
    try {
      final found = await FirebaseFirestore.instance.collection('users')
        .where('username', isEqualTo: name).limit(1).get();
      if (found.docs.isEmpty) throw Exception('Usuário não encontrado');
      final friend = found.docs.first;
      if (friend.id == widget.uid) throw Exception('Você não pode adicionar a si mesmo');
      await FirebaseFirestore.instance.collection('users').doc(widget.uid)
        .collection('friends').doc(friend.id).set({
          'username': name, 'createdAt': FieldValue.serverTimestamp(),
        });
      if (mounted) setState(() { status = 'Amigo adicionado!'; username.clear(); });
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(16), child: Column(children: [
    const Align(alignment: Alignment.centerLeft,
      child: Text('Amigos', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
    const SizedBox(height: 14),
    Row(children: [
      Expanded(child: TextField(controller: username,
        decoration: const InputDecoration(hintText: 'Nome de usuário'))),
      IconButton(onPressed: addFriend, icon: const Icon(Icons.person_add, color: purple)),
    ]),
    if (status != null) Padding(padding: const EdgeInsets.all(8), child: Text(status!)),
    Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(widget.uid)
        .collection('friends').snapshots(),
      builder: (context, snap) => ListView(children: [for (final doc in snap.data?.docs ?? [])
        ListTile(leading: const Icon(Icons.person, color: purple),
          title: Text(doc.data()['username']?.toString() ?? '?')),
      ]),
    )),
    const Text('Pedidos de amizade e mensagens privadas serão adicionados depois.',
      style: TextStyle(color: Colors.white54, fontSize: 12)),
  ]));
}

class ProfilePage extends StatelessWidget {
  final String uid;
  const ProfilePage({super.key, required this.uid});
  @override
  Widget build(BuildContext context) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
    stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
    builder: (context, snap) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const CircleAvatar(radius: 45, backgroundColor: purple,
        child: Icon(Icons.pets, size: 42)),
      const SizedBox(height: 16),
      Text('@${snap.data?.data()?['username'] ?? 'meow'}',
        style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
      const SizedBox(height: 24),
      OutlinedButton(onPressed: () => FirebaseAuth.instance.signOut(),
        child: const Text('Sair da conta')),
    ])),
  );
}
