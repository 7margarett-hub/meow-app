import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_selector/file_selector.dart' as files;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

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
    await Future.wait<void>([
      Future<void>.delayed(const Duration(milliseconds: 1000)),
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
        if (!snap.hasData && snap.connectionState == ConnectionState.waiting) return const LoadingCat();
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
  void dispose() { username.dispose(); password.dispose(); super.dispose(); }

  Future<void> submit() async {
    final name = cleanName(username.text);
    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(name)) {
      setState(() => error = 'Use 3 a 20 letras minúsculas, números ou _.'); return;
    }
    if (password.text.length < 8) {
      setState(() => error = 'A senha precisa ter pelo menos 8 caracteres.'); return;
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
    } catch (e) { if (mounted) setState(() => error = '$e'); }
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
  String channelName = 'geral';
  int tab = 0;
  bool showingChannels = true;
  final Set<String> collapsed = {};
  String get uid => FirebaseAuth.instance.currentUser!.uid;

  void notice(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<String?> prompt(String title, String hint, {int maxLength = 40}) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true, maxLength: maxLength,
        decoration: InputDecoration(hintText: hint)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Confirmar')),
      ],
    ));
    controller.dispose();
    return result;
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
        'name': 'geral', 'category': 'GERAL', 'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() { serverId = server.id; channelId = null; tab = 0; showingChannels = true; });
    } catch (e) { notice('Não foi possível criar: $e'); }
  }

  Future<void> createChannel() async {
    if (serverId == null) return;
    final name = await prompt('Criar canal', 'Nome do canal');
    if (name == null || name.isEmpty) return;
    if (!mounted) return;
    final category = await prompt('Categoria do canal', 'Ex.: CONVERSAS (vazio = GERAL)');
    if (category == null) return;
    try {
      await db.collection('servers').doc(serverId).collection('channels').add({
        'name': name, 'category': category.trim().isEmpty ? 'GERAL' : category.trim().toUpperCase(),
        'createdAt': FieldValue.serverTimestamp(),
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
      final code = newCode();
      await db.collection('invites').doc(code).set({
        'serverId': serverId, 'createdBy': uid,
        'createdAt': FieldValue.serverTimestamp(), 'active': true,
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
      notice('Digite um código válido de 10 caracteres.'); return;
    }
    try {
      final invite = await db.collection('invites').doc(code).get();
      final data = invite.data();
      if (data == null || data['active'] != true || data['serverId'] is! String) {
        notice('Convite inválido ou desativado.'); return;
      }
      final id = data['serverId'] as String;
      final batch = db.batch();
      final proofRef = db.collection('joinProofs').doc(id).collection('users').doc(uid);
      final serverRef = db.collection('servers').doc(id);
      batch.set(proofRef, {'serverId': id, 'code': code});
      batch.update(serverRef, {'members': FieldValue.arrayUnion([uid])});
      await batch.commit();
      if (mounted) setState(() { serverId = id; channelId = null; tab = 0; showingChannels = true; });
      notice('Você entrou no servidor!');
    } catch (e) { notice('Não foi possível entrar. Confira as regras do Firebase: $e'); }
  }

  void selectChannel(String id, String name) {
    setState(() { channelId = id; channelName = name; showingChannels = false; });
  }

  Widget serverRail() => SizedBox(width: 68, child: ColoredBox(
    color: const Color(0xFF0B0C11),
    child: Column(children: [
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
                onPressed: () => setState(() {
                  serverId = doc.id; channelId = null; showingChannels = true;
                }),
                icon: PrivateImage(scope: 'server', id: doc.id, slot: 'avatar', size: 32)),
            )),
          ]);
        },
      )),
    ]),
  ));

  Widget channelList(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final groups = <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
    for (final doc in docs) {
      final raw = doc.data()['category']?.toString().trim() ?? '';
      final category = raw.isEmpty ? 'GERAL' : raw.toUpperCase();
      groups.putIfAbsent(category, () => []).add(doc);
    }
    return ListView(children: [
      for (final entry in groups.entries) ...[
        ListTile(
          dense: true,
          leading: Icon(collapsed.contains(entry.key) ? Icons.chevron_right : Icons.expand_more,
            size: 20, color: Colors.white70),
          title: Text(entry.key, style: const TextStyle(fontSize: 12,
            fontWeight: FontWeight.bold, color: Colors.white70)),
          onTap: () => setState(() {
            if (!collapsed.add(entry.key)) collapsed.remove(entry.key);
          }),
        ),
        if (!collapsed.contains(entry.key))
          for (final doc in entry.value)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Material(
                color: channelId == doc.id ? purple.withValues(alpha: 0.25) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.tag, size: 20, color: Colors.white60),
                  title: Text(doc.data()['name']?.toString() ?? 'canal',
                    style: TextStyle(color: channelId == doc.id ? Colors.white : Colors.white70)),
                  onTap: () => selectChannel(doc.id, doc.data()['name']?.toString() ?? 'canal'),
                ),
              ),
            ),
      ],
    ]);
  }

  Widget serverContent() {
    if (serverId == null) {
      return Row(children: [serverRail(), const Expanded(child: Center(
        child: Text('Crie um servidor ou entre com um convite.')))]);
    }
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      key: ValueKey('channels-$serverId'),
      stream: db.collection('servers').doc(serverId).collection('channels').snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Erro nos canais: ${snap.error}'));
        final docs = snap.data?.docs ?? [];
        final active = docs.any((d) => d.id == channelId)
          ? channelId : (docs.isEmpty ? null : docs.first.id);
        if (active != channelId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || active == channelId) return;
            setState(() {
              channelId = active;
              final matches = docs.where((d) => d.id == active);
              if (matches.isNotEmpty) channelName = matches.first.data()['name']?.toString() ?? 'canal';
            });
          });
        }
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) {
            final speed = details.primaryVelocity ?? 0;
            if (speed > 250 && !showingChannels) setState(() => showingChannels = true);
            if (speed < -250 && showingChannels && active != null) {
              setState(() => showingChannels = false);
            }
          },
          child: showingChannels ? Row(children: [
            serverRail(),
            Expanded(child: ColoredBox(color: panel, child: Column(children: [
              ServerHeader(key: ValueKey(serverId), id: serverId!),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
                const Expanded(child: Text('Canais', style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold))),
                IconButton(tooltip: 'Novo canal', onPressed: createChannel,
                  icon: const Icon(Icons.add)),
                IconButton(tooltip: 'Gerar convite', onPressed: createInvite,
                  icon: const Icon(Icons.share)),
              ])),
              const Divider(height: 1),
              Expanded(child: channelList(docs)),
            ]))),
          ]) : Column(children: [
            Material(color: panel, child: SafeArea(bottom: false, child: Row(children: [
              IconButton(tooltip: 'Ver canais', icon: const Icon(Icons.menu),
                onPressed: () => setState(() => showingChannels = true)),
              const Icon(Icons.tag, color: Colors.white70, size: 20),
              const SizedBox(width: 6),
              Expanded(child: Text(channelName, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17))),
            ]))),
            Expanded(child: active == null
              ? const Center(child: Text('Selecione um canal'))
              : ChatPage(key: ValueKey('$serverId/$active'),
                  serverId: serverId!, channelId: active, uid: uid)),
          ]),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('🐱 Meow'), actions: [
      IconButton(tooltip: 'Sair', onPressed: () => FirebaseAuth.instance.signOut(),
        icon: const Icon(Icons.logout)),
    ]),
    body: Column(children: [
      Expanded(child: tab == 1 ? FriendsPage(uid: uid)
        : tab == 2 ? DmListPage(uid: uid)
        : tab == 3 ? ProfilePage(uid: uid) : serverContent()),
      NavigationBar(height: 70, selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i), destinations: const [
          NavigationDestination(icon: Icon(Icons.tag), label: 'Canais'),
          NavigationDestination(icon: Icon(Icons.people), label: 'Amigos'),
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'DMs'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Perfil'),
        ]),
    ]),
  );
}

// Mensagens de servidores e DMs usam o mesmo menu e editor.
class ChatPage extends StatelessWidget {
  final String serverId, channelId, uid;
  const ChatPage({super.key, required this.serverId, required this.channelId, required this.uid});
  @override
  Widget build(BuildContext context) => MessageThread(
    key: ValueKey('server-$serverId-$channelId'),
    collection: FirebaseFirestore.instance.collection('servers').doc(serverId)
      .collection('channels').doc(channelId).collection('messages'),
    uid: uid, serverId: serverId,
  );
}

String dmId(String a, String b) {
  final ids = [a, b]..sort();
  return '${ids[0]}_${ids[1]}';
}

Future<void> openDm(BuildContext context, String otherUid) async {
  final me = FirebaseAuth.instance.currentUser?.uid;
  if (me == null || otherUid.isEmpty || me == otherUid) return;
  final id = dmId(me, otherUid);
  try {
    await FirebaseFirestore.instance.collection('dms').doc(id).set({
      'members': [me, otherUid],
    }, SetOptions(merge: true));
    if (!context.mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => DmChatPage(
      dmIdValue: id, otherUid: otherUid, uid: me)));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Não foi possível abrir a DM: $e')));
  }
}

class DmListPage extends StatelessWidget {
  final String uid;
  const DmListPage({super.key, required this.uid});
  @override
  Widget build(BuildContext context) => Column(children: [
    const Padding(padding: EdgeInsets.all(16), child: Align(
      alignment: Alignment.centerLeft,
      child: Text('Mensagens privadas', style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold)))),
    Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('dms')
        .where('members', arrayContains: uid).snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Erro ao carregar DMs: ${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        if (snap.data!.docs.isEmpty) return const Center(
          child: Text('Abra o perfil de alguém e toque em Enviar mensagem.'));
        return ListView(children: [for (final doc in snap.data!.docs)
          Builder(builder: (context) {
            final members = List<String>.from(doc.data()['members'] ?? []);
            final others = members.where((id) => id != uid).toList();
            if (others.isEmpty) return const SizedBox.shrink();
            final other = others.first;
            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance.collection('users').doc(other).snapshots(),
              builder: (context, userSnap) {
                final data = userSnap.data?.data();
                return ListTile(
                  leading: ProfileAvatar(uid: other),
                  title: Text(data?['displayName']?.toString() ??
                    data?['username']?.toString() ?? 'Usuário'),
                  subtitle: const Text('Mensagem privada'),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) =>
                    DmChatPage(dmIdValue: doc.id, otherUid: other, uid: uid))),
                );
              });
          }),
        ]);
      },
    )),
  ]);
}

class DmChatPage extends StatelessWidget {
  final String dmIdValue, otherUid, uid;
  const DmChatPage({super.key, required this.dmIdValue,
    required this.otherUid, required this.uid});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(otherUid).snapshots(),
      builder: (context, snap) => Text(snap.data?.data()?['displayName']?.toString() ??
        snap.data?.data()?['username']?.toString() ?? 'Mensagem privada'))),
    body: MessageThread(
      collection: FirebaseFirestore.instance.collection('dms').doc(dmIdValue)
        .collection('messages'), uid: uid),
  );
}

class MessageThread extends StatefulWidget {
  final CollectionReference<Map<String, dynamic>> collection;
  final String uid;
  final String? serverId;
  const MessageThread({super.key, required this.collection, required this.uid, this.serverId});
  @override
  State<MessageThread> createState() => _MessageThreadState();
}

class _MessageThreadState extends State<MessageThread> {
  final input = TextEditingController();
  bool sending = false;
  String? replyingId, replyingText, replyingAuthor;
  @override
  void dispose() { input.dispose(); super.dispose(); }

  void notice(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      final user = await FirebaseFirestore.instance.collection('users').doc(widget.uid).get();
      final data = <String, dynamic>{
        'text': text, 'authorId': widget.uid,
        'author': user.data()?['displayName'] ?? user.data()?['username'] ?? 'Usuário',
        'createdAt': FieldValue.serverTimestamp(),
      };
      if (replyingId != null) {
        data['replyToId'] = replyingId;
        data['replyText'] = replyingText;
        data['replyAuthor'] = replyingAuthor;
      }
      await widget.collection.add(data);
      input.clear();
      if (mounted) setState(() { replyingId = null; replyingText = null; replyingAuthor = null; });
    } catch (e) { notice('Falha ao enviar: $e'); }
    if (mounted) setState(() => sending = false);
  }

  Future<bool> isServerAdmin() async {
    if (widget.serverId == null) return false;
    final server = await FirebaseFirestore.instance.collection('servers').doc(widget.serverId).get();
    final data = server.data();
    // A estrutura atual usa ownerId. Outros administradores podem ser
    // reconhecidos futuramente pelo campo opcional adminIds.
    final admins = data?['adminIds'];
    return data?['ownerId'] == widget.uid ||
      (admins is List && admins.contains(widget.uid));
  }

  Future<void> editMessage(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final current = doc.data()['text']?.toString() ?? '';
    final controller = TextEditingController(text: current);
    final next = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Editar mensagem'),
      content: TextField(controller: controller, maxLength: 2000, maxLines: 5, minLines: 1),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Salvar')),
      ],
    ));
    // Não descartar o controller antes da animação de fechamento do diálogo.
    if (next == null || next.isEmpty || next == current) return;
    try {
      await doc.reference.update({'text': next, 'editedAt': FieldValue.serverTimestamp()});
    } catch (e) { notice('Não foi possível editar: $e'); }
  }

  Future<void> deleteMessage(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Apagar mensagem?'),
      content: const Text('Esta ação não pode ser desfeita.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apagar')),
      ],
    ));
    if (confirm != true) return;
    try { await doc.reference.delete(); }
    catch (e) { notice('Não foi possível apagar: $e'); }
  }

  Future<void> messageOptions(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final data = doc.data();
    final own = data['authorId'] == widget.uid;
    bool admin = false;
    if (!own && widget.serverId != null) {
      try { admin = await isServerAdmin(); }
      catch (e) { notice('Não foi possível verificar permissões: $e'); return; }
    }
    if (!mounted) return;
    final action = await showModalBottomSheet<String>(context: context,
      backgroundColor: panel, showDragHandle: true, builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.reply), title: const Text('Responder'),
            onTap: () => Navigator.pop(ctx, 'reply')),
          if (own && data['text'] is String)
            ListTile(leading: const Icon(Icons.edit), title: const Text('Editar mensagem'),
              onTap: () => Navigator.pop(ctx, 'edit')),
          if (own || admin)
            ListTile(leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('Apagar mensagem', style: TextStyle(color: Colors.redAccent)),
              onTap: () => Navigator.pop(ctx, 'delete')),
        ])));
    if (!mounted) return;
    if (action == 'reply') {
      setState(() {
        replyingId = doc.id;
        replyingText = data['text']?.toString() ?? '';
        replyingAuthor = data['author']?.toString() ?? 'Usuário';
      });
    } else if (action == 'edit' && own) {
      await editMessage(doc);
    } else if (action == 'delete' && (own || admin)) {
      await deleteMessage(doc);
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
    Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: widget.collection.orderBy('createdAt', descending: true).limit(100).snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Erro ao carregar: ${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final docs = snap.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('Diga oi! 👋'));
        return ListView.builder(reverse: true, padding: const EdgeInsets.all(12),
          itemCount: docs.length, itemBuilder: (context, i) {
            final doc = docs[i];
            final data = doc.data();
            final authorId = data['authorId']?.toString() ?? '';
            return InkWell(
              onLongPress: () => messageOptions(doc),
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ProfileAvatar(uid: authorId),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    InkWell(onTap: () => openProfile(context, authorId), child: Text(
                      data['author']?.toString() ?? 'Usuário',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: purple))),
                    if (data['replyToId'] != null)
                      Container(margin: const EdgeInsets.only(top: 4, bottom: 4),
                        padding: const EdgeInsets.all(7),
                        decoration: const BoxDecoration(border: Border(
                          left: BorderSide(color: purple, width: 3))),
                        child: Text('${data['replyAuthor'] ?? 'Usuário'}: ${data['replyText'] ?? ''}',
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Colors.white70))),
                    Text(data['text']?.toString() ?? '',
                      style: const TextStyle(fontSize: 15, color: Colors.white)),
                    if (data['editedAt'] != null)
                      const Text('(editada)', style: TextStyle(fontSize: 11, color: Colors.white54)),
                  ])),
                ]),
              ),
            );
          });
      },
    )),
    if (replyingId != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        const Icon(Icons.reply, color: purple), const SizedBox(width: 8),
        Expanded(child: Text('Respondendo a $replyingAuthor: $replyingText',
          maxLines: 1, overflow: TextOverflow.ellipsis)),
        IconButton(onPressed: () => setState(() {
          replyingId = null; replyingText = null; replyingAuthor = null;
        }), icon: const Icon(Icons.close)),
      ])),
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
    } catch (e) { if (mounted) setState(() => status = '$e'); }
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
    const Text('Toque em um amigo para abrir o perfil e enviar uma mensagem.',
      style: TextStyle(color: Colors.white54, fontSize: 12)),
  ]));
}

class LoadingCat extends StatefulWidget {
  const LoadingCat({super.key});
  @override
  State<LoadingCat> createState() => _LoadingCatState();
}

class _LoadingCatState extends State<LoadingCat> with SingleTickerProviderStateMixin {
  late final spin = AnimationController(vsync: this,
    duration: const Duration(milliseconds: 1600))..repeat();
  @override
  void dispose() { spin.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: Colors.black,
    body: Center(child: RotationTransition(turns: spin,
      child: const Icon(Icons.pets, color: Colors.white, size: 100))));
}

const imageHost = 'ffxsvctvcsldumxnkiob.supabase.co';
const imageLimit = 8 * 1024 * 1024;
final changedImage = ValueNotifier<Uri?>(null);

Uri mediaUrl(String scope, String id, String slot) => Uri.https(imageHost,
  '/functions/v1/meow-imagens', {'scope': scope, 'id': id, 'slot': slot});

Future<Map<String, String>> authHeaders() async {
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
    final response = await http.get(uri, headers: await authHeaders())
      .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) return null;
    return response.bodyBytes;
  }
  @override
  void initState() {
    super.initState(); bytes = load(widget.url); changedImage.addListener(refresh);
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
          return Image.memory(data, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback);
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
      final response = await http.put(uri, headers: headers, body: data)
        .timeout(const Duration(seconds: 90));
      if (response.statusCode != 200) {
        String message = 'Falha ao enviar (HTTP ${response.statusCode}).';
        try { message = jsonDecode(response.body)['error']?.toString() ?? message; }
        on FormatException { }
        throw Exception(message);
      }
      changedImage.value = null; changedImage.value = uri;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Imagem salva.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => TextButton(onPressed: busy ? null : choose,
    child: Text(busy ? 'Enviando…' : widget.label));
}

void openProfile(BuildContext context, String uid) {
  if (uid.isEmpty) return;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: panel,
    barrierColor: Colors.black.withValues(alpha: 0.65),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (ctx, scrollController) => Column(children: [
        const SizedBox(height: 10),
        Container(width: 42, height: 5, decoration: BoxDecoration(
          color: Colors.white30, borderRadius: BorderRadius.circular(10))),
        const SizedBox(height: 8),
        Expanded(child: ProfilePage(uid: uid, expanded: true,
          scrollController: scrollController)),
      ]),
    ),
  );
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
  Widget build(BuildContext context) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
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
  final ScrollController? scrollController;
  const ProfilePage({super.key, required this.uid,
    this.expanded = false, this.scrollController});

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
        'displayName': values.first.isEmpty ? FieldValue.delete() : values.first,
        'pronouns': values.last,
      });
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro ao salvar: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
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
      return ListView(controller: scrollController,
        padding: const EdgeInsets.all(16), children: [
        PrivateImage(scope: 'profile', id: uid, slot: 'banner', size: 134),
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerLeft, child: InkWell(
          onTap: expanded ? null : () => openProfile(context, uid),
          child: PrivateImage(scope: 'profile', id: uid, slot: 'avatar', size: 80))),
        const SizedBox(height: 12),
        Text(name, style: Theme.of(context).textTheme.headlineSmall),
        Text('@$username'),
        if (pronouns.isNotEmpty) Text(pronouns),
        if (!own) ...[
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: () async {
            final navContext = Navigator.of(context).context;
            if (expanded) Navigator.of(context).pop();
            await openDm(navContext, uid);
          }, icon: const Icon(Icons.message_outlined), label: const Text('Enviar mensagem')),
        ],
        if (own) ...[
          const SizedBox(height: 18),
          Wrap(children: [ChangeImage('profile', uid, 'avatar', 'Trocar foto'),
            ChangeImage('profile', uid, 'banner', 'Trocar banner')]),
          OutlinedButton(onPressed: () => edit(context, name, pronouns),
            child: const Text('Editar perfil')),
          TextButton(onPressed: () => FirebaseAuth.instance.signOut().then((_) {
            if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
          }), child: const Text('Sair da conta')),
        ],
      ]);
    });
}
