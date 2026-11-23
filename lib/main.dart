import 'dart:convert';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart' as files;
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
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
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: LoadingCat()));
  try {
    await Future.wait<void>([Future<void>.delayed(const Duration(milliseconds: 1000)),
      Firebase.initializeApp(options: const FirebaseOptions(
      apiKey: apiKey, appId: appId, messagingSenderId: senderId, projectId: projectId,
    )).then<void>((_) {}),
    ]);
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
    title: 'Meow', debugShowCheckedModeBanner: false,
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
          return const LoadingCat();
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
      // Matches the Firestore invite schema, including the active flag.
      final code = newCode();
      await db.collection('invites').doc(code).set({
        'serverId': serverId,
        'createdBy': uid,
        'createdAt': FieldValue.serverTimestamp(),
        'active': true,
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
      if (data == null || data['active'] != true || data['serverId'] is! String) {
        notice('Convite inválido ou desativado.');
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
    appBar: AppBar(title: const Text('🐱 Meow'), actions: [
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
                    icon: PrivateImage(scope: 'server', id: doc.id, slot: 'avatar', size: 32)),
                )),
              ]);
            },
          )),
        ]))),
        Expanded(child: serverId == null
          ? const Center(child: Text('Crie um servidor ou entre com um convite.'))
          : Column(children: [
            ServerHeader(key: ValueKey(serverId), id: serverId!),
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
        'author': user.data()?['displayName'] ?? user.data()?['username'] ?? 'Usuário',
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
              leading: ProfileAvatar(uid: data['authorId']?.toString() ?? ''),
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
        ListTile(leading: ProfileAvatar(uid: doc.id), onTap: () => openProfile(context, doc.id),
          title: Text(doc.data()['username']?.toString() ?? '?')),
      ]),
    )),
    const Text('Pedidos de amizade e mensagens privadas serão adicionados depois.',
      style: TextStyle(color: Colors.white54, fontSize: 12)),
  ]));
}


final _cat = base64Decode('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');

class LoadingCat extends StatefulWidget {
  const LoadingCat({super.key});
  @override
  State<LoadingCat> createState() => _LoadingCatState();
}

class _LoadingCatState extends State<LoadingCat> with SingleTickerProviderStateMixin {
  late final spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  @override
  void dispose() { spin.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: Colors.black,
    body: Center(child: RotationTransition(turns: spin, child: Image.memory(_cat, width: 100))));
}

const imageHost = 'ffxsvctvcsldumxnkiob.supabase.co';
const imageLimit = 8 * 1024 * 1024;
final changedImage = ValueNotifier<Uri?>(null);

Uri mediaUrl(String scope, String id, String slot) => Uri.https(imageHost,
  '/functions/v1/meow-imagens', {'scope': scope, 'id': id, 'slot': slot});

Future<Map<String,String>> authHeaders() async {
  final token = await FirebaseAuth.instance.currentUser?.getIdToken();
  if (token == null) throw Exception('Entre novamente no Meow.');
  return {'Authorization': 'Bearer $token'};
}

class PrivateImage extends StatefulWidget {
  final String scope, id, slot;
  final double size;
  const PrivateImage({super.key, required this.scope, required this.id,
    required this.slot, required this.size});
  Uri get url => mediaUrl(scope, id, slot);
  @override
  State<PrivateImage> createState() => _PrivateImageState();
}

class _PrivateImageState extends State<PrivateImage> {
  late Future<Uint8List?> bytes;
  Future<Uint8List?> load(Uri uri) async {
    final response = await http.get(uri, headers: await authHeaders()).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) return null;
    return response.bodyBytes;
  }
  @override
  void initState() {
    super.initState();
    bytes = load(widget.url);
    changedImage.addListener(refresh);
  }
  void refresh() {
    if (changedImage.value == widget.url) setState(() => bytes = load(widget.url));
  }
  @override
  void didUpdateWidget(PrivateImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) bytes = load(widget.url);
  }
  @override
  void dispose() { changedImage.removeListener(refresh); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final banner = widget.slot == 'banner';
    final fallback = ColoredBox(color: panel, child: Center(child: Icon(
      banner ? Icons.landscape : widget.scope == 'server' ? Icons.groups : Icons.person,
      color: Colors.white54, size: banner ? 30 : widget.size * .6)));
    return SizedBox(width: banner ? double.infinity : widget.size, height: widget.size,
      child: ClipRRect(borderRadius: BorderRadius.circular(banner ? 8 : widget.size),
        child: FutureBuilder<Uint8List?>(key: ValueKey(widget.url), future: bytes, builder: (_, snap) {
          final data = snap.data;
          if (data == null) return fallback;
          return Image.memory(data, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback);
        })));
  }
}

class ChangeImage extends StatefulWidget {
  final String scope, id, slot, label;
  const ChangeImage(this.scope, this.id, this.slot, this.label, {super.key});
  @override
  State<ChangeImage> createState() => _ChangeImageState();
}

class _ChangeImageState extends State<ChangeImage> {
  bool busy = false;
  Future<void> choose() async {
    if (busy) return;
    final uri = mediaUrl(widget.scope, widget.id, widget.slot);
    setState(() => busy = true);
    try {
      final source = await showModalBottomSheet<String>(context: context, builder: (ctx) =>
        SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_library), title: const Text('Escolher da galeria'),
            onTap: () => Navigator.pop(ctx, 'gallery')),
          ListTile(leading: const Icon(Icons.folder_open), title: const Text('Escolher dos arquivos'),
            onTap: () => Navigator.pop(ctx, 'files')),
        ])));
      if (source == null) return;
      final file = source == 'gallery'
        ? await ImagePicker().pickImage(source: ImageSource.gallery, requestFullMetadata: false)
        : await files.openFile(acceptedTypeGroups: const [files.XTypeGroup(
          label: 'Imagens', extensions: ['jpg','jpeg','png','webp','gif'],
          mimeTypes: ['image/jpeg','image/png','image/webp','image/gif'],
          uniformTypeIdentifiers: ['public.jpeg','public.png','org.webmproject.webp','com.compuserve.gif'])]);
      if (file == null) return;
      if (await file.length() > imageLimit) throw Exception('Escolha uma imagem de até 8 MiB.');
      final data = await file.readAsBytes();
      final headers = await authHeaders();
      final response = await http.put(uri, headers: headers, body: data).timeout(const Duration(seconds: 90));
      if (response.statusCode != 200) {
        String message = 'Falha ao enviar (HTTP ${response.statusCode}).';
        try { message = jsonDecode(response.body)['error']?.toString() ?? message; } on FormatException { }
        throw Exception(message);
      }
      changedImage.value = null;
      changedImage.value = uri;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Imagem salva.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  @override
  Widget build(BuildContext context) => TextButton(onPressed: busy ? null : choose,
    child: Text(busy ? 'Enviando…' : widget.label));
}

void openProfile(BuildContext context, String uid) {
  if (uid.isEmpty) return;
  Navigator.push<void>(context, MaterialPageRoute(builder: (_) => Scaffold(
    appBar: AppBar(title: const Text('Perfil')), body: ProfilePage(uid: uid, expanded: true))));
}

class ProfileAvatar extends StatelessWidget {
  final String uid;
  const ProfileAvatar({super.key, required this.uid});
  @override
  Widget build(BuildContext context) => InkWell(onTap: () => openProfile(context, uid),
    child: PrivateImage(scope: 'profile', id: uid, slot: 'avatar', size: 40));
}

class ServerHeader extends StatelessWidget {
  final String id;
  const ServerHeader({super.key, required this.id});
  @override
  Widget build(BuildContext context) => StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
    stream: FirebaseFirestore.instance.collection('servers').doc(id).snapshots(),
    builder: (_, snap) {
      final server = snap.data?.data();
      return Column(children: [
        PrivateImage(scope: 'server', id: id, slot: 'banner', size: 54),
        if (server?['ownerId'] == FirebaseAuth.instance.currentUser?.uid && server != null)
          Wrap(children: [ChangeImage('server', id, 'avatar', 'Trocar ícone'),
            ChangeImage('server', id, 'banner', 'Trocar banner')]),
      ]);
    });
}

class ProfilePage extends StatelessWidget {
  final String uid;
  final bool expanded;
  const ProfilePage({super.key, required this.uid, this.expanded = false});

  Future<void> edit(BuildContext context, String name, String pronouns) async {
    final values = await showDialog<List<String>>(context: context, builder: (ctx) {
      return AlertDialog(title: const Text('Editar perfil'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(initialValue: name, maxLength: 40, onChanged: (v) => name = v,
            decoration: const InputDecoration(labelText: 'Nome de exibição')),
          TextFormField(initialValue: pronouns, maxLength: 40, onChanged: (v) => pronouns = v,
            decoration: const InputDecoration(labelText: 'Pronomes')),
        ])), actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, [name.trim(), pronouns.trim()]),
            child: const Text('Salvar')),
        ]);
    });
    if (values == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'displayName': values.first.isEmpty ? FieldValue.delete() : values.first, 'pronouns': values.last});
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao salvar: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
    stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
    builder: (context, snap) {
      if (snap.hasError) return const Center(child: Text('Não foi possível abrir o perfil.'));
      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
      final data = snap.data!.data();
      if (data == null) return const Center(child: Text('Perfil indisponível.'));
      final username = data['username']?.toString() ?? 'meow';
      final name = data['displayName']?.toString() ?? username;
      final pronouns = data['pronouns']?.toString() ?? '';
      final own = FirebaseAuth.instance.currentUser?.uid == uid;
      return ListView(padding: const EdgeInsets.all(16), children: [
        PrivateImage(scope: 'profile', id: uid, slot: 'banner', size: 134),
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerLeft, child: InkWell(
          onTap: expanded ? null : () => openProfile(context, uid),
          child: PrivateImage(scope: 'profile', id: uid, slot: 'avatar', size: 80))),
        const SizedBox(height: 12),
        Text(name, style: Theme.of(context).textTheme.headlineSmall),
        Text('@$username'),
        if (pronouns.isNotEmpty) Text(pronouns),
        if (own) ...[
          const SizedBox(height: 18),
          Wrap(children: [ChangeImage('profile', uid, 'avatar', 'Trocar foto'),
            ChangeImage('profile', uid, 'banner', 'Trocar banner')]),
          OutlinedButton(onPressed: () => edit(context, name, pronouns), child: const Text('Editar perfil')),
          TextButton(onPressed: () => FirebaseAuth.instance.signOut().then((_) {
            if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
          }), child: const Text('Sair da conta')),
        ]
      ]);
    });
}
