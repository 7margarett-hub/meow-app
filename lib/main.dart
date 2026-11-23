import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

const ink = Color(0xFF111218);
const surface = Color(0xFF1C1D28);
const accent = Color(0xFF8B5CF6);
const subtle = Color(0xFFAAAABC);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const apiKey = String.fromEnvironment('FB_API_KEY');
  const appId = String.fromEnvironment('FB_APP_ID');
  const senderId = String.fromEnvironment('FB_SENDER_ID');
  const projectId = String.fromEnvironment('FB_PROJECT_ID');
  if ([apiKey, appId, senderId, projectId].any((v) => v.isEmpty)) {
    runApp(const MaterialApp(home: SetupPage()));
    return;
  }
  try {
    await Firebase.initializeApp(options: const FirebaseOptions(
      apiKey: apiKey, appId: appId, messagingSenderId: senderId, projectId: projectId,
    ));
    runApp(const MeowApp());
  } catch (e) {
    runApp(MaterialApp(home: Scaffold(body: Center(child: Padding(
      padding: const EdgeInsets.all(24), child: Text('Falha ao conectar Firebase: $e'),
    )))));
  }
}

class SetupPage extends StatelessWidget {
  const SetupPage({super.key});
  @override Widget build(BuildContext context) => const Scaffold(
    backgroundColor: ink,
    body: SafeArea(child: Center(child: Padding(
      padding: EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.pets, size: 68, color: accent), SizedBox(height: 16),
        Text('Meow Social', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
        SizedBox(height: 12), Text('Falta configurar o Firebase no GitHub Actions. Consulte o README do projeto.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
      ]),
    ))),
  );
}

class MeowApp extends StatelessWidget {
  const MeowApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'Meow', debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: ink,
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
      appBarTheme: const AppBarTheme(backgroundColor: surface),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: surface, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    home: StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        return snapshot.data == null ? const LoginPage() : const SocialHome();
      },
    ),
  );
}

String normalized(String name) => name.trim().toLowerCase();
String authEmail(String name) => '${normalized(name)}@users.meow.invalid';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override State<LoginPage> createState() => _LoginPageState();
}
class _LoginPageState extends State<LoginPage> {
  final name = TextEditingController();
  final password = TextEditingController();
  bool register = false, busy = false;
  String? error;
  Future<void> submit() async {
    final username = normalized(name.text);
    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(username)) {
      setState(() => error = 'Use 3 a 20 caracteres: letras minúsculas, números ou _.'); return;
    }
    if (password.text.length < 8) { setState(() => error = 'Use uma senha com pelo menos 8 caracteres.'); return; }
    setState(() { busy = true; error = null; });
    try {
      if (register) {
        final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: authEmail(username), password: password.text);
        await FirebaseFirestore.instance.collection('users').doc(cred.user!.uid).set({
          'username': username, 'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(email: authEmail(username), password: password.text);
      }
    } on FirebaseAuthException catch (e) {
      setState(() => error = switch(e.code) {
        'email-already-in-use' => 'Este usuário já existe.',
        'invalid-credential' => 'Usuário ou senha incorretos.',
        'weak-password' => 'Escolha uma senha mais forte.',
        _ => 'Não foi possível entrar: ${e.code}',
      });
    } catch (e) { setState(() => error = 'Erro: $e'); }
    if (mounted) setState(() => busy = false);
  }
  @override Widget build(BuildContext context) => Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(
    padding: const EdgeInsets.all(28), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Column(
      mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.pets, color: accent, size: 64), const SizedBox(height: 10),
        Text(register ? 'Criar conta Meow' : 'Entrar no Meow', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const SizedBox(height: 24), TextField(controller: name, autocorrect: false, decoration: const InputDecoration(labelText: 'Nome de usuário')),
        const SizedBox(height: 12), TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Senha')),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
        const SizedBox(height: 16), FilledButton(onPressed: busy ? null : submit, child: Text(busy ? 'Aguarde...' : register ? 'Criar conta' : 'Entrar')),
        TextButton(onPressed: busy ? null : () => setState(() { register = !register; error = null; }),
          child: Text(register ? 'Já tenho conta' : 'Criar uma conta')),
        const Text('Versão inicial: convites e recuperação administrativa serão adicionados depois.', textAlign: TextAlign.center, style: TextStyle(color: subtle, fontSize: 12)),
      ],
    ))),
  ))));
}

class SocialHome extends StatefulWidget {
  const SocialHome({super.key});
  @override State<SocialHome> createState() => _SocialHomeState();
}
class _SocialHomeState extends State<SocialHome> {
  String? serverId, channelId;
  int tab = 0;
  final db = FirebaseFirestore.instance;
  String get uid => FirebaseAuth.instance.currentUser!.uid;
  Future<String?> ask(String title, String hint) async {
    final c = TextEditingController();
    return showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: Text(title), content: TextField(controller: c, autofocus: true, maxLength: 40, decoration: InputDecoration(hintText: hint)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Salvar'))],
    ));
  }
  void snack(String msg) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg))); }
  Future<void> createServer() async {
    final name = await ask('Novo servidor', 'Nome do servidor');
    if (name == null || name.isEmpty) return;
    try {
      final doc = await db.collection('servers').add({'name': name, 'ownerId': uid, 'members': [uid], 'createdAt': FieldValue.serverTimestamp()});
      await doc.collection('channels').add({'name': 'geral', 'createdAt': FieldValue.serverTimestamp()});
      setState(() { serverId = doc.id; channelId = null; tab = 0; });
    } catch (e) { snack('Não foi possível criar servidor: $e'); }
  }
  Future<void> joinServer() async {
    final code = await ask('Entrar em servidor', 'Cole o ID do servidor');
    if (code == null || code.isEmpty) return;
    try {
      final doc = db.collection('servers').doc(code);
      await doc.update({'members': FieldValue.arrayUnion([uid])});
      setState(() { serverId = code; channelId = null; tab = 0; });
    } catch (e) { snack('Não foi possível entrar: $e'); }
  }
  Future<void> createChannel() async {
    if (serverId == null) return;
    final name = await ask('Novo canal', 'Nome do canal');
    if (name == null || name.isEmpty) return;
    try { await db.collection('servers').doc(serverId).collection('channels').add({'name': name, 'createdAt': FieldValue.serverTimestamp()}); }
    catch (e) { snack('Erro ao criar canal: $e'); }
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('🐱 Meow'), actions: [IconButton(tooltip: 'Sair', onPressed: () => FirebaseAuth.instance.signOut(), icon: const Icon(Icons.logout))]),
    body: Column(children: [
      Expanded(child: tab == 1 ? FriendsPage(uid: uid) : tab == 2 ? ProfilePage(uid: uid) : Row(children: [
        SizedBox(width: 76, child: ColoredBox(color: const Color(0xFF0B0C11), child: Column(children: [
          IconButton(tooltip: 'Criar servidor', onPressed: createServer, icon: const Icon(Icons.add_circle, color: accent)),
          IconButton(tooltip: 'Entrar com ID', onPressed: joinServer, icon: const Icon(Icons.group_add)),
          Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: db.collection('servers').where('members', arrayContains: uid).snapshots(),
            builder: (context, snap) => ListView(children: [for (final doc in snap.data?.docs ?? [])
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: CircleAvatar(
                backgroundColor: serverId == doc.id ? accent : surface,
                child: IconButton(tooltip: doc.data()['name']?.toString() ?? 'Servidor', onPressed: () => setState(() { serverId = doc.id; channelId = null; }),
                  icon: Text((doc.data()['name']?.toString() ?? 'S').substring(0, 1).toUpperCase(), style: const TextStyle(color: Colors.white))),
              ))]),
          )),
        ]))),
        Expanded(child: serverId == null ? const Center(child: Text('Crie ou entre em um servidor!')) : Column(children: [
          Container(color: surface, padding: const EdgeInsets.all(10), child: Row(children: [
            const Expanded(child: Text('Canais', style: TextStyle(fontWeight: FontWeight.bold))),
            IconButton(onPressed: createChannel, icon: const Icon(Icons.add)),
            IconButton(tooltip: 'Copiar ID do servidor', onPressed: () => showDialog<void>(context: context, builder: (ctx) => AlertDialog(
              title: const Text('Convide seus amigos'), content: SelectableText(serverId!),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fechar'))],
            )), icon: const Icon(Icons.share)),
          ])),
          SizedBox(height: 58, child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: db.collection('servers').doc(serverId).collection('channels').snapshots(),
            builder: (context, snap) {
              final docs = snap.data?.docs ?? [];
              final active = docs.any((d) => d.id == channelId) ? channelId : (docs.isNotEmpty ? docs.first.id : null);
              if (active != channelId) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && channelId != active) setState(() => channelId = active); });
              return ListView(scrollDirection: Axis.horizontal, children: [for (final doc in docs)
                Padding(padding: const EdgeInsets.all(5), child: ChoiceChip(label: Text('# ${doc.data()['name']}'), selected: active == doc.id,
                  onSelected: (_) => setState(() => channelId = doc.id)))],);
            },
          )),
          Expanded(child: channelId == null ? const Center(child: Text('Escolha um canal')) : ChatPage(key: ValueKey('$serverId/$channelId'), serverId: serverId!, channelId: channelId!, uid: uid)),
        ])),
      ])),
      NavigationBar(height: 70, selectedIndex: tab, onDestinationSelected: (i) => setState(() => tab = i), destinations: const [
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
  @override State<ChatPage> createState() => _ChatPageState();
}
class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController();
  bool sending = false;
  CollectionReference<Map<String, dynamic>> get messages => FirebaseFirestore.instance.collection('servers').doc(widget.serverId)
    .collection('channels').doc(widget.channelId).collection('messages');
  Future<void> send() async {
    final text = input.text.trim(); if (text.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      final user = await FirebaseFirestore.instance.collection('users').doc(widget.uid).get();
      await messages.add({'text': text, 'authorId': widget.uid, 'author': user.data()?['username'] ?? 'Usuário', 'createdAt': FieldValue.serverTimestamp()});
      input.clear();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao enviar: $e'))); }
    if (mounted) setState(() => sending = false);
  }
  @override Widget build(BuildContext context) => Column(children: [
    Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: messages.orderBy('createdAt', descending: true).limit(100).snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Erro ao carregar mensagens: ${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        if (snap.data!.docs.isEmpty) return const Center(child: Text('Diga oi! 👋'));
        return ListView.builder(reverse: true, padding: const EdgeInsets.all(12), itemCount: snap.data!.docs.length, itemBuilder: (context, i) {
          final data = snap.data!.docs[i].data();
          return ListTile(contentPadding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
            leading: CircleAvatar(backgroundColor: accent, child: Text((data['author']?.toString() ?? '?').substring(0, 1).toUpperCase())),
            title: Text(data['author']?.toString() ?? 'Usuário', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            subtitle: Text(data['text']?.toString() ?? '', style: const TextStyle(fontSize: 15, color: Colors.white)),
          );
        });
      },
    )),
    SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
      Expanded(child: TextField(controller: input, minLines: 1, maxLines: 4, maxLength: 2000,
        decoration: const InputDecoration(hintText: 'Mensagem', counterText: ''), onSubmitted: (_) => send())),
      IconButton(onPressed: sending ? null : send, icon: const Icon(Icons.send, color: accent)),
    ]))),
  ]);
}

class FriendsPage extends StatefulWidget {
  final String uid;
  const FriendsPage({super.key, required this.uid});
  @override State<FriendsPage> createState() => _FriendsPageState();
}
class _FriendsPageState extends State<FriendsPage> {
  final username = TextEditingController();
  String? message;
  Future<void> addFriend() async {
    final name = normalized(username.text);
    if (name.isEmpty) return;
    try {
      final found = await FirebaseFirestore.instance.collection('users').where('username', isEqualTo: name).limit(1).get();
      if (found.docs.isEmpty) throw Exception('Usuário não encontrado');
      final friend = found.docs.first;
      if (friend.id == widget.uid) throw Exception('Você não pode adicionar a si mesmo');
      await FirebaseFirestore.instance.collection('users').doc(widget.uid).collection('friends').doc(friend.id).set({'username': name, 'createdAt': FieldValue.serverTimestamp()});
      if (mounted) setState(() { message = 'Amigo adicionado à sua lista'; username.clear(); });
    } catch (e) { if (mounted) setState(() => message = e.toString()); }
  }
  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Amigos', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)), const SizedBox(height: 14),
    Row(children: [Expanded(child: TextField(controller: username, decoration: const InputDecoration(hintText: 'Nome de usuário'))),
      IconButton(onPressed: addFriend, icon: const Icon(Icons.person_add, color: accent))]),
    if (message != null) Padding(padding: const EdgeInsets.all(8), child: Text(message!)),
    const SizedBox(height: 8),
    Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(widget.uid).collection('friends').snapshots(),
      builder: (context, snap) => ListView(children: [for (final doc in snap.data?.docs ?? [])
        ListTile(leading: const Icon(Icons.person, color: accent), title: Text(doc.data()['username']?.toString() ?? '?'))]),
    )),
    const Text('Lista pessoal de amigos. Solicitações e mensagens diretas virão na próxima atualização.', style: TextStyle(color: subtle, fontSize: 12)),
  ]));
}

class ProfilePage extends StatelessWidget {
  final String uid;
  const ProfilePage({super.key, required this.uid});
  @override Widget build(BuildContext context) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
    stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
    builder: (context, snap) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const CircleAvatar(radius: 45, backgroundColor: accent, child: Icon(Icons.pets, size: 42, color: Colors.white)),
      const SizedBox(height: 16), Text('@${snap.data?.data()?['username'] ?? 'meow'}', style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8), const Text('Meu perfil', style: TextStyle(color: subtle)),
      const SizedBox(height: 24), OutlinedButton(onPressed: () => FirebaseAuth.instance.signOut(), child: const Text('Sair da conta')),
    ])),
  );
}
