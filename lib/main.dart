
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

const avatarLimit = 8 * 1024 * 1024;
const bannerLimit = 15 * 1024 * 1024;
const imageHost = 'ffxsvctvcsldumxnkiob.supabase.co';

final changedImage = ValueNotifier<Uri?>(null);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const apiKey = String.fromEnvironment('FB_API_KEY');
  const appId = String.fromEnvironment('FB_APP_ID');
  const senderId = String.fromEnvironment('FB_SENDER_ID');
  const projectId = String.fromEnvironment('FB_PROJECT_ID');

  if ([apiKey, appId, senderId, projectId].any((v) => v.isEmpty)) {
    runApp(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('Configure o Firebase no GitHub Actions.'),
        ),
      ),
    ));
    return;
  }

  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: LoadingCat(),
  ));

  try {
    await Future.wait<void>([
      Future<void>.delayed(const Duration(milliseconds: 1000)),
      Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: apiKey,
          appId: appId,
          messagingSenderId: senderId,
          projectId: projectId,
        ),
      ).then<void>((_) {}),
    ]);

    runApp(const MeowApp());
  } catch (e) {
    runApp(MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Erro ao iniciar Firebase: $e')),
      ),
    ));
  }
}

String cleanName(String value) => value.trim().toLowerCase();

String loginEmail(String name) =>
    '${cleanName(name)}@users.meow.invalid';

void showNotice(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}

Uri mediaUrl(String scope, String id, String slot) {
  return Uri.https(
    imageHost,
    '/functions/v1/meow-imagens',
    {
      'scope': scope,
      'id': id,
      'slot': slot,
    },
  );
}

Future<Map<String, String>> authHeaders() async {
  final token = await FirebaseAuth.instance.currentUser?.getIdToken();

  if (token == null) {
    throw Exception('Entre novamente no Meow.');
  }

  return {'Authorization': 'Bearer $token'};
}

class MeowApp extends StatelessWidget {
  const MeowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: purple,
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: panel,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: panel,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snap) {
          if (!snap.hasData &&
              snap.connectionState == ConnectionState.waiting) {
            return const LoadingCat();
          }

          return snap.data == null
              ? const LoginPage()
              : const SocialHome();
        },
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final username = TextEditingController();
  final password = TextEditingController();

  bool register = false;
  bool loading = false;
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
      setState(() {
        error = 'Use 3 a 20 letras minúsculas, números ou _.';
      });
      return;
    }

    if (password.text.length < 8) {
      setState(() {
        error = 'A senha precisa ter pelo menos 8 caracteres.';
      });
      return;
    }

    setState(() {
      loading = true;
      error = null;
    });

    try {
      if (register) {
        final credential =
            await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: loginEmail(name),
          password: password.text,
        );

        await FirebaseFirestore.instance
            .collection('users')
            .doc(credential.user!.uid)
            .set({
          'username': name,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: loginEmail(name),
          password: password.text,
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          error = e.code == 'email-already-in-use'
              ? 'Esse nome já está em uso.'
              : 'Falha no login: ${e.code}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    }

    if (mounted) {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.pets,
                    size: 70,
                    color: purple,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    register ? 'Criar conta Meow' : 'Entrar no Meow',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: username,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Usuário',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Senha',
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        error!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: loading ? null : submit,
                    child: Text(
                      loading
                          ? 'Aguarde...'
                          : register
                              ? 'Criar conta'
                              : 'Entrar',
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        register = !register;
                        error = null;
                      });
                    },
                    child: Text(
                      register ? 'Já tenho conta' : 'Criar conta',
                    ),
                  ),
                  const Text(
                    'O aplicativo usa um identificador interno no Firebase. '
                    'Você não precisa digitar e-mail.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LoadingCat extends StatefulWidget {
  const LoadingCat({super.key});

  @override
  State<LoadingCat> createState() => _LoadingCatState();
}

class _LoadingCatState extends State<LoadingCat>
    with SingleTickerProviderStateMixin {
  late final AnimationController spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: RotationTransition(
          turns: spin,
          child: const Icon(
            Icons.pets,
            color: Colors.white,
            size: 100,
          ),
        ),
      ),
    );
  }
}

// ============================================================
// IMAGENS PRIVADAS
// ============================================================

class PrivateImage extends StatefulWidget {
  final String scope;
  final String id;
  final String slot;
  final double size;
  final double? width;
  final BorderRadius? borderRadius;

  const PrivateImage({
    super.key,
    required this.scope,
    required this.id,
    required this.slot,
    required this.size,
    this.width,
    this.borderRadius,
  });

  Uri get url => mediaUrl(scope, id, slot);

  @override
  State<PrivateImage> createState() => _PrivateImageState();
}

class _PrivateImageState extends State<PrivateImage> {
  late Future<Uint8List?> bytes;

  Future<Uint8List?> load(Uri uri) async {
    try {
      final response = await http
          .get(uri, headers: await authHeaders())
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        return null;
      }

      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    bytes = load(widget.url);
    changedImage.addListener(refresh);
  }

  void refresh() {
    if (changedImage.value == widget.url && mounted) {
      setState(() {
        bytes = load(widget.url);
      });
    }
  }

  @override
  void didUpdateWidget(covariant PrivateImage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.url != widget.url) {
      bytes = load(widget.url);
    }
  }

  @override
  void dispose() {
    changedImage.removeListener(refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banner = widget.slot == 'banner';

    final fallback = ColoredBox(
      color: panel,
      child: Center(
        child: Icon(
          banner
              ? Icons.landscape_outlined
              : widget.scope == 'server'
                  ? Icons.groups
                  : Icons.person,
          color: Colors.white54,
          size: banner ? 42 : widget.size * .55,
        ),
      ),
    );

    return SizedBox(
      width: widget.width ?? (banner ? double.infinity : widget.size),
      height: widget.size,
      child: ClipRRect(
        borderRadius: widget.borderRadius ??
            BorderRadius.circular(banner ? 12 : widget.size),
        child: FutureBuilder<Uint8List?>(
          future: bytes,
          builder: (context, snap) {
            final data = snap.data;

            if (data == null) {
              return fallback;
            }

            return Image.memory(
              data,
              width: double.infinity,
              height: widget.size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => fallback,
            );
          },
        ),
      ),
    );
  }
}

class ChangeImage extends StatefulWidget {
  final String scope;
  final String id;
  final String slot;
  final String label;
  final bool iconOnly;
  final bool outlined;

  const ChangeImage(
    this.scope,
    this.id,
    this.slot,
    this.label, {
    super.key,
    this.iconOnly = false,
    this.outlined = false,
  });

  @override
  State<ChangeImage> createState() => _ChangeImageState();
}

class _ChangeImageState extends State<ChangeImage> {
  bool busy = false;

  Future<void> choose() async {
    if (busy) return;

    final uri = mediaUrl(
      widget.scope,
      widget.id,
      widget.slot,
    );

    setState(() => busy = true);

    try {
      final source = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: panel,
        showDragHandle: true,
        builder: (ctx) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Escolher da galeria'),
                  onTap: () => Navigator.pop(ctx, 'gallery'),
                ),
                ListTile(
                  leading: const Icon(Icons.folder_open),
                  title: const Text('Escolher dos arquivos'),
                  onTap: () => Navigator.pop(ctx, 'files'),
                ),
              ],
            ),
          );
        },
      );

      if (source == null) return;

      final file = source == 'gallery'
          ? await ImagePicker().pickImage(
              source: ImageSource.gallery,
              requestFullMetadata: false,
            )
          : await files.openFile(
              acceptedTypeGroups: const [
                files.XTypeGroup(
                  label: 'Imagens',
                  extensions: [
                    'jpg',
                    'jpeg',
                    'png',
                    'webp',
                    'gif',
                  ],
                  mimeTypes: [
                    'image/jpeg',
                    'image/png',
                    'image/webp',
                    'image/gif',
                  ],
                ),
              ],
            );

      if (file == null) return;

      final isBanner = widget.slot == 'banner';
      final maxBytes = isBanner ? bannerLimit : avatarLimit;
      final maxMiB = isBanner ? 15 : 8;

      if (await file.length() > maxBytes) {
        throw Exception(
          'Escolha uma imagem de até $maxMiB MiB.',
        );
      }

      final data = await file.readAsBytes();

      final response = await http
          .put(
            uri,
            headers: await authHeaders(),
            body: data,
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode != 200) {
        String message =
            'Falha ao enviar (HTTP ${response.statusCode}).';

        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['error'] != null) {
            message = body['error'].toString();
          }
        } catch (_) {}

        throw Exception(message);
      }

      changedImage.value = null;
      changedImage.value = uri;

      if (mounted) {
        showNotice(context, 'Imagem salva com sucesso!');
      }
    } catch (e) {
      if (mounted) {
        showNotice(context, '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.iconOnly) {
      return IconButton.filledTonal(
        tooltip: widget.label,
        onPressed: busy ? null : choose,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                ),
              )
            : const Icon(Icons.camera_alt_outlined),
      );
    }

    if (widget.outlined) {
      return OutlinedButton.icon(
        onPressed: busy ? null : choose,
        icon: const Icon(Icons.image_outlined),
        label: Text(busy ? 'Enviando...' : widget.label),
      );
    }

    return TextButton(
      onPressed: busy ? null : choose,
      child: Text(busy ? 'Enviando...' : widget.label),
    );
  }
}

// ============================================================
// PERFIS
// ============================================================

void openProfile(BuildContext context, String uid) {
  if (uid.isEmpty) return;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: panel,
    barrierColor: Colors.black.withValues(alpha: .65),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(24),
      ),
    ),
    builder: (ctx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: .82,
        minChildSize: .35,
        maxChildSize: .96,
        builder: (ctx, controller) {
          return Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.white30,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ProfilePage(
                  uid: uid,
                  expanded: true,
                  scrollController: controller,
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

class ProfileAvatar extends StatelessWidget {
  final String uid;
  final double size;

  const ProfileAvatar({
    super.key,
    required this.uid,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(size),
      onTap: () => openProfile(context, uid),
      child: PrivateImage(
        scope: 'profile',
        id: uid,
        slot: 'avatar',
        size: size,
      ),
    );
  }
}

class ProfilePage extends StatelessWidget {
  final String uid;
  final bool expanded;
  final ScrollController? scrollController;

  const ProfilePage({
    super.key,
    required this.uid,
    this.expanded = false,
    this.scrollController,
  });

  Future<void> openEditor(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditProfilePage(uid: uid),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return const Center(
            child: Text('Não foi possível abrir o perfil.'),
          );
        }

        if (!snap.hasData) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        final data = snap.data!.data();

        if (data == null) {
          return const Center(
            child: Text('Perfil indisponível.'),
          );
        }

        final username =
            data['username']?.toString() ?? 'meow';
        final name =
            data['displayName']?.toString() ?? username;
        final pronouns =
            data['pronouns']?.toString() ?? '';
        final bio = data['bio']?.toString() ?? '';
        final own =
            FirebaseAuth.instance.currentUser?.uid == uid;

        return ListView(
          controller: scrollController,
          padding: EdgeInsets.zero,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                PrivateImage(
                  scope: 'profile',
                  id: uid,
                  slot: 'banner',
                  size: 180,
                  borderRadius: BorderRadius.zero,
                ),
                Positioned(
                  bottom: -44,
                  left: 18,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: panel,
                      shape: BoxShape.circle,
                    ),
                    child: PrivateImage(
                      scope: 'profile',
                      id: uid,
                      slot: 'avatar',
                      size: 88,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 56),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 18,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '@$username',
                    style: const TextStyle(
                      color: Colors.white60,
                    ),
                  ),
                  if (pronouns.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      pronouns,
                      style: const TextStyle(
                        color: Colors.white70,
                      ),
                    ),
                  ],
                  if (bio.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text(
                      'SOBRE MIM',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white60,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(bio),
                  ],
                  const SizedBox(height: 22),
                  if (own)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => openEditor(context),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Editar perfil'),
                      ),
                    ),
                  if (!own)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () async {
                          final navigator = Navigator.of(context);
                          final targetContext = navigator.context;

                          if (expanded) {
                            navigator.pop();
                          }

                          await openDm(targetContext, uid);
                        },
                        icon: const Icon(
                          Icons.message_outlined,
                        ),
                        label: const Text('Enviar mensagem'),
                      ),
                    ),
                  if (own && !expanded) ...[
                    const SizedBox(height: 10),
                    Center(
                      child: TextButton.icon(
                        onPressed: () =>
                            FirebaseAuth.instance.signOut(),
                        icon: const Icon(Icons.logout),
                        label: const Text('Sair da conta'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class EditProfilePage extends StatefulWidget {
  final String uid;

  const EditProfilePage({
    super.key,
    required this.uid,
  });

  @override
  State<EditProfilePage> createState() =>
      _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final nameController = TextEditingController();
  final pronounsController = TextEditingController();
  final bioController = TextEditingController();

  bool loaded = false;
  bool saving = false;

  @override
  void dispose() {
    nameController.dispose();
    pronounsController.dispose();
    bioController.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving) return;

    final name = nameController.text.trim();
    final pronouns = pronounsController.text.trim();
    final bio = bioController.text.trim();

    if (name.length > 40 ||
        pronouns.length > 40 ||
        bio.length > 300) {
      showNotice(context, 'Confira os limites dos campos.');
      return;
    }

    setState(() => saving = true);

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .update({
        'displayName':
            name.isEmpty ? FieldValue.delete() : name,
        'pronouns': pronouns,
        'bio': bio,
      });

      if (mounted) {
        showNotice(context, 'Perfil atualizado!');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        showNotice(context, 'Erro ao salvar: $e');
      }
    } finally {
      if (mounted) {
        setState(() => saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Editar perfil'),
      ),
      body: StreamBuilder<
          DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(widget.uid)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(
              child: Text('Erro ao carregar perfil.'),
            );
          }

          if (!snap.hasData) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          final data = snap.data!.data() ?? {};

          if (!loaded) {
            nameController.text =
                data['displayName']?.toString() ?? '';
            pronounsController.text =
                data['pronouns']?.toString() ?? '';
            bioController.text =
                data['bio']?.toString() ?? '';
            loaded = true;
          }

          return ListView(
            padding: const EdgeInsets.only(
              bottom: 32,
            ),
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      PrivateImage(
                        scope: 'profile',
                        id: widget.uid,
                        slot: 'banner',
                        size: 180,
                        borderRadius: BorderRadius.zero,
                      ),
                      Positioned(
                        right: 12,
                        top: 12,
                        child: ChangeImage(
                          'profile',
                          widget.uid,
                          'banner',
                          'Alterar banner',
                          iconOnly: true,
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    left: 18,
                    bottom: -46,
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: bg,
                            shape: BoxShape.circle,
                          ),
                          child: PrivateImage(
                            scope: 'profile',
                            id: widget.uid,
                            slot: 'avatar',
                            size: 90,
                          ),
                        ),
                        ChangeImage(
                          'profile',
                          widget.uid,
                          'avatar',
                          'Alterar foto',
                          iconOnly: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 65),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PERSONALIZAÇÃO',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Toque na câmera sobre a foto ou o banner '
                      'para trocar a imagem.',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: nameController,
                      maxLength: 40,
                      decoration: const InputDecoration(
                        labelText: 'Nome de exibição',
                        hintText: 'Como quer aparecer no Meow?',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: pronounsController,
                      maxLength: 40,
                      decoration: const InputDecoration(
                        labelText: 'Pronomes',
                        hintText: 'Ex.: ela/dela',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: bioController,
                      maxLength: 300,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Sobre mim',
                        hintText: 'Conte um pouco sobre você...',
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: saving ? null : save,
                        icon: saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check),
                        label: Text(
                          saving ? 'Salvando...' : 'Salvar alterações',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ============================================================
// SERVIDORES
// ============================================================

class ServerHeader extends StatelessWidget {
  final String id;

  const ServerHeader({
    super.key,
    required this.id,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<
        DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('servers')
          .doc(id)
          .snapshots(),
      builder: (context, snap) {
        final server = snap.data?.data();
        final name =
            server?['name']?.toString() ?? 'Servidor';
        final members =
            server?['members'] is List
                ? (server!['members'] as List).length
                : 0;

        final own = server?['ownerId'] ==
            FirebaseAuth.instance.currentUser?.uid;

        return Column(
          children: [
            Stack(
              children: [
                PrivateImage(
                  scope: 'server',
                  id: id,
                  slot: 'banner',
                  size: 160,
                  borderRadius: BorderRadius.zero,
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 55,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: .65),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                12,
                12,
                8,
                10,
              ),
              child: Row(
                children: [
                  PrivateImage(
                    scope: 'server',
                    id: id,
                    slot: 'avatar',
                    size: 42,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '$members membros',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (own)
                    IconButton(
                      tooltip: 'Configurações do servidor',
                      icon: const Icon(
                        Icons.settings_outlined,
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                ServerSettingsPage(id: id),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],
        );
      },
    );
  }
}

class ServerSettingsPage extends StatelessWidget {
  final String id;

  const ServerSettingsPage({
    super.key,
    required this.id,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configurações do servidor'),
      ),
      body: StreamBuilder<
          DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('servers')
            .doc(id)
            .snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          final data = snap.data?.data();

          if (data == null) {
            return const Center(
              child: Text('Servidor indisponível.'),
            );
          }

          final own = data['ownerId'] ==
              FirebaseAuth.instance.currentUser?.uid;

          if (!own) {
            return const Center(
              child: Text(
                'Somente o proprietário pode editar este servidor.',
              ),
            );
          }

          return ListView(
            children: [
              PrivateImage(
                scope: 'server',
                id: id,
                slot: 'banner',
                size: 160,
                borderRadius: BorderRadius.zero,
              ),
              const SizedBox(height: 18),
              Center(
                child: PrivateImage(
                  scope: 'server',
                  id: id,
                  slot: 'avatar',
                  size: 88,
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  data['name']?.toString() ?? 'Servidor',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                ),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'APARÊNCIA',
                      style: TextStyle(
                        color: Colors.white60,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ChangeImage(
                      'server',
                      id,
                      'avatar',
                      'Alterar ícone do servidor',
                      outlined: true,
                    ),
                    const SizedBox(height: 8),
                    ChangeImage(
                      'server',
                      id,
                      'banner',
                      'Alterar banner do servidor',
                      outlined: true,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Ícones: até 8 MiB.\n'
                      'Banners: até 15 MiB.\n'
                      'Formatos: JPG, PNG, WebP e GIF.',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ============================================================
// TELA PRINCIPAL
// ============================================================

class SocialHome extends StatefulWidget {
  const SocialHome({super.key});

  @override
  State<SocialHome> createState() => _SocialHomeState();
}

class _SocialHomeState extends State<SocialHome> {
  final db = FirebaseFirestore.instance;

  String? serverId;
  String? channelId;
  String channelName = 'geral';

  int tab = 0;
  bool showingChannels = true;

  final Set<String> collapsed = {};

  String get uid =>
      FirebaseAuth.instance.currentUser!.uid;

  void notice(String message) {
    if (mounted) showNotice(context, message);
  }

  Future<String?> prompt(
    String title,
    String hint, {
    int maxLength = 40,
  }) async {
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: maxLength,
            decoration: InputDecoration(
              hintText: hint,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Confirmar'),
            ),
          ],
        );
      },
    );

    controller.dispose();
    return result;
  }

  Future<void> createServer() async {
    final name = await prompt(
      'Criar servidor',
      'Nome do servidor',
    );

    if (name == null || name.isEmpty) return;

    try {
      final server = await db.collection('servers').add({
        'name': name,
        'ownerId': uid,
        'members': [uid],
        'createdAt': FieldValue.serverTimestamp(),
      });

      await server.collection('channels').add({
        'name': 'geral',
        'category': 'GERAL',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        setState(() {
          serverId = server.id;
          channelId = null;
          tab = 0;
          showingChannels = true;
        });
      }
    } catch (e) {
      notice('Não foi possível criar: $e');
    }
  }

  Future<void> createChannel() async {
    if (serverId == null) return;

    final name = await prompt(
      'Criar canal',
      'Nome do canal',
    );

    if (name == null || name.isEmpty) return;
    if (!mounted) return;

    final category = await prompt(
      'Categoria do canal',
      'Ex.: CONVERSAS (vazio = GERAL)',
    );

    if (category == null) return;

    try {
      await db
          .collection('servers')
          .doc(serverId)
          .collection('channels')
          .add({
        'name': name,
        'category': category.trim().isEmpty
            ? 'GERAL'
            : category.trim().toUpperCase(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      notice('Não foi possível criar canal: $e');
    }
  }

  String newCode() {
    const alphabet =
        'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

    final random = Random.secure();

    return List.generate(
      10,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  Future<void> createInvite() async {
    if (serverId == null) return;

    try {
      final code = newCode();

      await db.collection('invites').doc(code).set({
        'serverId': serverId,
        'createdBy': uid,
        'createdAt': FieldValue.serverTimestamp(),
        'active': true,
      });

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Convite do Meow'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Compartilhe este código com um amigo:',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  code,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(text: code),
                  );
                  Navigator.pop(ctx);
                  notice('Código copiado!');
                },
                child: const Text('Copiar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Fechar'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      notice('Não foi possível gerar convite: $e');
    }
  }

  Future<void> joinInvite() async {
    final input = await prompt(
      'Entrar com convite',
      'Código de 10 caracteres',
      maxLength: 20,
    );

    if (input == null || input.isEmpty) return;

    final code = input.trim().toUpperCase();

    if (!RegExp(r'^[A-HJ-NP-Z2-9]{10}$').hasMatch(code)) {
      notice('Digite um código válido de 10 caracteres.');
      return;
    }

    try {
      final invite =
          await db.collection('invites').doc(code).get();

      final data = invite.data();

      if (data == null ||
          data['active'] != true ||
          data['serverId'] is! String) {
        notice('Convite inválido ou desativado.');
        return;
      }

      final id = data['serverId'] as String;
      final batch = db.batch();

      final proofRef = db
          .collection('joinProofs')
          .doc(id)
          .collection('users')
          .doc(uid);

      final serverRef = db.collection('servers').doc(id);

      batch.set(proofRef, {
        'serverId': id,
        'code': code,
      });

      batch.update(serverRef, {
        'members': FieldValue.arrayUnion([uid]),
      });

      await batch.commit();

      if (mounted) {
        setState(() {
          serverId = id;
          channelId = null;
          tab = 0;
          showingChannels = true;
        });
      }

      notice('Você entrou no servidor!');
    } catch (e) {
      notice(
        'Não foi possível entrar. Confira as regras do Firebase: $e',
      );
    }
  }

  void selectChannel(String id, String name) {
    setState(() {
      channelId = id;
      channelName = name;
      showingChannels = false;
    });
  }

  Widget serverRail() {
    return SizedBox(
      width: 68,
      child: ColoredBox(
        color: const Color(0xFF0B0C11),
        child: Column(
          children: [
            IconButton(
              tooltip: 'Criar servidor',
              onPressed: createServer,
              icon: const Icon(
                Icons.add_circle,
                color: purple,
              ),
            ),
            IconButton(
              tooltip: 'Entrar com convite',
              onPressed: joinInvite,
              icon: const Icon(Icons.group_add),
            ),
            Expanded(
              child: StreamBuilder<
                  QuerySnapshot<Map<String, dynamic>>>(
                stream: db
                    .collection('servers')
                    .where(
                      'members',
                      arrayContains: uid,
                    )
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const Center(
                      child: Icon(Icons.error_outline),
                    );
                  }

                  return ListView(
                    children: [
                      for (final doc in snap.data?.docs ?? [])
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 5,
                          ),
                          child: CircleAvatar(
                            backgroundColor:
                                serverId == doc.id
                                    ? purple
                                    : panel,
                            child: IconButton(
                              tooltip: doc.data()['name']
                                      ?.toString() ??
                                  'Servidor',
                              onPressed: () {
                                setState(() {
                                  serverId = doc.id;
                                  channelId = null;
                                  showingChannels = true;
                                });
                              },
                              icon: PrivateImage(
                                scope: 'server',
                                id: doc.id,
                                slot: 'avatar',
                                size: 32,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget channelList(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final groups = <String,
        List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};

    for (final doc in docs) {
      final raw =
          doc.data()['category']?.toString().trim() ?? '';

      final category =
          raw.isEmpty ? 'GERAL' : raw.toUpperCase();

      groups.putIfAbsent(category, () => []).add(doc);
    }

    return ListView(
      children: [
        for (final entry in groups.entries) ...[
          ListTile(
            dense: true,
            leading: Icon(
              collapsed.contains(entry.key)
                  ? Icons.chevron_right
                  : Icons.expand_more,
              size: 20,
              color: Colors.white70,
            ),
            title: Text(
              entry.key,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white70,
              ),
            ),
            onTap: () {
              setState(() {
                if (!collapsed.add(entry.key)) {
                  collapsed.remove(entry.key);
                }
              });
            },
          ),
          if (!collapsed.contains(entry.key))
            for (final doc in entry.value)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                child: Material(
                  color: channelId == doc.id
                      ? purple.withValues(alpha: .25)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.tag,
                      size: 20,
                      color: Colors.white60,
                    ),
                    title: Text(
                      doc.data()['name']?.toString() ??
                          'canal',
                      style: TextStyle(
                        color: channelId == doc.id
                            ? Colors.white
                            : Colors.white70,
                      ),
                    ),
                    onTap: () => selectChannel(
                      doc.id,
                      doc.data()['name']?.toString() ??
                          'canal',
                    ),
                  ),
                ),
              ),
        ],
      ],
    );
  }

  Widget serverContent() {
    if (serverId == null) {
      return Row(
        children: [
          serverRail(),
          const Expanded(
            child: Center(
              child: Text(
                'Crie um servidor ou entre com um convite.',
              ),
            ),
          ),
        ],
      );
    }

    return StreamBuilder<
        QuerySnapshot<Map<String, dynamic>>>(
      key: ValueKey('channels-$serverId'),
      stream: db
          .collection('servers')
          .doc(serverId)
          .collection('channels')
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text('Erro nos canais: ${snap.error}'),
          );
        }

        final docs = snap.data?.docs ?? [];

        final active = docs.any((d) => d.id == channelId)
            ? channelId
            : docs.isEmpty
                ? null
                : docs.first.id;

        if (active != channelId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || active == channelId) return;

            setState(() {
              channelId = active;

              final matches =
                  docs.where((d) => d.id == active);

              if (matches.isNotEmpty) {
                channelName = matches.first
                        .data()['name']
                        ?.toString() ??
                    'canal';
              }
            });
          });
        }

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) {
            final speed =
                details.primaryVelocity ?? 0;

            if (speed > 250 && !showingChannels) {
              setState(() => showingChannels = true);
            }

            if (speed < -250 &&
                showingChannels &&
                active != null) {
              setState(() => showingChannels = false);
            }
          },
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(.04, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: showingChannels
                ? Row(
                    key: const ValueKey('channel-list'),
                    children: [
                      serverRail(),
                      Expanded(
                        child: ColoredBox(
                          color: panel,
                          child: Column(
                            children: [
                              ServerHeader(
                                key: ValueKey(serverId),
                                id: serverId!,
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        'Canais',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight:
                                              FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Novo canal',
                                      onPressed: createChannel,
                                      icon: const Icon(Icons.add),
                                    ),
                                    IconButton(
                                      tooltip: 'Gerar convite',
                                      onPressed: createInvite,
                                      icon: const Icon(Icons.share),
                                    ),
                                  ],
                                ),
                              ),
                              const Divider(height: 1),
                              Expanded(
                                child: channelList(docs),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    key: const ValueKey('channel-chat'),
                    children: [
                      Material(
                        color: panel,
                        child: SafeArea(
                          bottom: false,
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: 'Ver canais',
                                icon: const Icon(Icons.menu),
                                onPressed: () {
                                  setState(() =>
                                      showingChannels = true);
                                },
                              ),
                              const Icon(
                                Icons.tag,
                                color: Colors.white70,
                                size: 20,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  channelName,
                                  overflow:
                                      TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight:
                                        FontWeight.bold,
                                    fontSize: 17,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: active == null
                            ? const Center(
                                child: Text(
                                  'Selecione um canal',
                                ),
                              )
                            : ChatPage(
                                key: ValueKey(
                                  '$serverId/$active',
                                ),
                                serverId: serverId!,
                                channelId: active,
                                uid: uid,
                              ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget selectedPage() {
    switch (tab) {
      case 1:
        return FriendsPage(
          key: const ValueKey('friends'),
          uid: uid,
        );
      case 2:
        return DmListPage(
          key: const ValueKey('dms'),
          uid: uid,
        );
      case 3:
        return ProfilePage(
          key: const ValueKey('profile'),
          uid: uid,
        );
      default:
        return KeyedSubtree(
          key: const ValueKey('servers'),
          child: serverContent(),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🐱 Meow'),
        actions: [
          IconButton(
            tooltip: 'Sair',
            onPressed: () =>
                FirebaseAuth.instance.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(
                milliseconds: 280,
              ),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(.035, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: selectedPage(),
            ),
          ),
          NavigationBar(
            height: 70,
            selectedIndex: tab,
            onDestinationSelected: (i) {
              setState(() => tab = i);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.tag),
                label: 'Canais',
              ),
              NavigationDestination(
                icon: Icon(Icons.people),
                label: 'Amigos',
              ),
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                label: 'DMs',
              ),
              NavigationDestination(
                icon: Icon(Icons.person),
                label: 'Perfil',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================
// MENSAGENS E DMs
// ============================================================

class ChatPage extends StatelessWidget {
  final String serverId;
  final String channelId;
  final String uid;

  const ChatPage({
    super.key,
    required this.serverId,
    required this.channelId,
    required this.uid,
  });

  @override
  Widget build(BuildContext context) {
    return MessageThread(
      key: ValueKey('server-$serverId-$channelId'),
      collection: FirebaseFirestore.instance
          .collection('servers')
          .doc(serverId)
          .collection('channels')
          .doc(channelId)
          .collection('messages'),
      uid: uid,
      serverId: serverId,
    );
  }
}

String dmId(String a, String b) {
  final ids = [a, b]..sort();
  return '${ids[0]}_${ids[1]}';
}

Future<void> openDm(
  BuildContext context,
  String otherUid,
) async {
  final me =
      FirebaseAuth.instance.currentUser?.uid;

  if (me == null ||
      otherUid.isEmpty ||
      me == otherUid) {
    return;
  }

  final id = dmId(me, otherUid);

  try {
    await FirebaseFirestore.instance
        .collection('dms')
        .doc(id)
        .set({
      'members': [me, otherUid],
    }, SetOptions(merge: true));

    if (!context.mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DmChatPage(
          dmIdValue: id,
          otherUid: otherUid,
          uid: me,
        ),
      ),
    );
  } catch (e) {
    if (context.mounted) {
      showNotice(
        context,
        'Não foi possível abrir a DM: $e',
      );
    }
  }
}

class DmListPage extends StatelessWidget {
  final String uid;

  const DmListPage({
    super.key,
    required this.uid,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Mensagens privadas',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<
              QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('dms')
                .where(
                  'members',
                  arrayContains: uid,
                )
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Text(
                    'Erro ao carregar DMs: ${snap.error}',
                  ),
                );
              }

              if (!snap.hasData) {
                return const Center(
                  child: CircularProgressIndicator(),
                );
              }

              if (snap.data!.docs.isEmpty) {
                return const Center(
                  child: Text(
                    'Abra o perfil de alguém e toque em '
                    'Enviar mensagem.',
                  ),
                );
              }

              return ListView(
                children: [
                  for (final doc in snap.data!.docs)
                    Builder(
                      builder: (context) {
                        final members =
                            List<String>.from(
                          doc.data()['members'] ?? [],
                        );

                        final others = members
                            .where((id) => id != uid)
                            .toList();

                        if (others.isEmpty) {
                          return const SizedBox.shrink();
                        }

                        final other = others.first;

                        return StreamBuilder<
                            DocumentSnapshot<
                                Map<String, dynamic>>>(
                          stream: FirebaseFirestore.instance
                              .collection('users')
                              .doc(other)
                              .snapshots(),
                          builder: (context, userSnap) {
                            final data =
                                userSnap.data?.data();

                            return ListTile(
                              leading: ProfileAvatar(
                                uid: other,
                              ),
                              title: Text(
                                data?['displayName']
                                        ?.toString() ??
                                    data?['username']
                                        ?.toString() ??
                                    'Usuário',
                              ),
                              subtitle: const Text(
                                'Mensagem privada',
                              ),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        DmChatPage(
                                      dmIdValue: doc.id,
                                      otherUid: other,
                                      uid: uid,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class DmChatPage extends StatelessWidget {
  final String dmIdValue;
  final String otherUid;
  final String uid;

  const DmChatPage({
    super.key,
    required this.dmIdValue,
    required this.otherUid,
    required this.uid,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: StreamBuilder<
            DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(otherUid)
              .snapshots(),
          builder: (context, snap) {
            return Text(
              snap.data?.data()?['displayName']
                      ?.toString() ??
                  snap.data?.data()?['username']
                      ?.toString() ??
                  'Mensagem privada',
            );
          },
        ),
      ),
      body: MessageThread(
        collection: FirebaseFirestore.instance
            .collection('dms')
            .doc(dmIdValue)
            .collection('messages'),
        uid: uid,
      ),
    );
  }
}

class MessageThread extends StatefulWidget {
  final CollectionReference<Map<String, dynamic>>
      collection;
  final String uid;
  final String? serverId;

  const MessageThread({
    super.key,
    required this.collection,
    required this.uid,
    this.serverId,
  });

  @override
  State<MessageThread> createState() =>
      _MessageThreadState();
}

class _MessageThreadState extends State<MessageThread> {
  final input = TextEditingController();

  bool sending = false;

  String? replyingId;
  String? replyingText;
  String? replyingAuthor;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void notice(String message) {
    if (mounted) {
      showNotice(context, message);
    }
  }

  Future<void> send() async {
    final text = input.text.trim();

    if (text.isEmpty || sending) return;

    setState(() => sending = true);

    try {
      final user = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .get();

      final data = <String, dynamic>{
        'text': text,
        'authorId': widget.uid,
        'author':
            user.data()?['displayName'] ??
                user.data()?['username'] ??
                'Usuário',
        'createdAt': FieldValue.serverTimestamp(),
      };

      if (replyingId != null) {
        data['replyToId'] = replyingId;
        data['replyText'] = replyingText;
        data['replyAuthor'] = replyingAuthor;
      }

      await widget.collection.add(data);

      input.clear();

      if (mounted) {
        setState(() {
          replyingId = null;
          replyingText = null;
          replyingAuthor = null;
        });
      }
    } catch (e) {
      notice('Falha ao enviar: $e');
    }

    if (mounted) {
      setState(() => sending = false);
    }
  }

  Future<bool> isServerAdmin() async {
    if (widget.serverId == null) {
      return false;
    }

    final server = await FirebaseFirestore.instance
        .collection('servers')
        .doc(widget.serverId)
        .get();

    final data = server.data();
    final admins = data?['adminIds'];

    return data?['ownerId'] == widget.uid ||
        (admins is List && admins.contains(widget.uid));
  }

  Future<void> editMessage(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final current =
        doc.data()['text']?.toString() ?? '';

    final controller =
        TextEditingController(text: current);

    final next = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Editar mensagem'),
          content: TextField(
            controller: controller,
            maxLength: 2000,
            maxLines: 5,
            minLines: 1,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                ctx,
                controller.text.trim(),
              ),
              child: const Text('Salvar'),
            ),
          ],
        );
      },
    );

    if (next == null ||
        next.isEmpty ||
        next == current) {
      return;
    }

    try {
      await doc.reference.update({
        'text': next,
        'editedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      notice('Não foi possível editar: $e');
    }
  }

  Future<void> deleteMessage(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Apagar mensagem?'),
          content: const Text(
            'Esta ação não pode ser desfeita.',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, true),
              child: const Text('Apagar'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    try {
      await doc.reference.delete();
    } catch (e) {
      notice('Não foi possível apagar: $e');
    }
  }

  Future<void> messageOptions(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final data = doc.data();
    final own = data['authorId'] == widget.uid;

    bool admin = false;

    if (!own && widget.serverId != null) {
      try {
        admin = await isServerAdmin();
      } catch (e) {
        notice(
          'Não foi possível verificar permissões: $e',
        );
        return;
      }
    }

    if (!mounted) return;

    final action =
        await showModalBottomSheet<String>(
      context: context,
      backgroundColor: panel,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Responder'),
                onTap: () =>
                    Navigator.pop(ctx, 'reply'),
              ),
              if (own && data['text'] is String)
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text(
                    'Editar mensagem',
                  ),
                  onTap: () =>
                      Navigator.pop(ctx, 'edit'),
                ),
              if (own || admin)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: const Text(
                    'Apagar mensagem',
                    style: TextStyle(
                      color: Colors.redAccent,
                    ),
                  ),
                  onTap: () =>
                      Navigator.pop(ctx, 'delete'),
                ),
            ],
          ),
        );
      },
    );

    if (!mounted) return;

    if (action == 'reply') {
      setState(() {
        replyingId = doc.id;
        replyingText =
            data['text']?.toString() ?? '';
        replyingAuthor =
            data['author']?.toString() ?? 'Usuário';
      });
    } else if (action == 'edit' && own) {
      await editMessage(doc);
    } else if (action == 'delete' &&
        (own || admin)) {
      await deleteMessage(doc);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: StreamBuilder<
              QuerySnapshot<Map<String, dynamic>>>(
            stream: widget.collection
                .orderBy(
                  'createdAt',
                  descending: true,
                )
                .limit(100)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Text(
                    'Erro ao carregar: ${snap.error}',
                  ),
                );
              }

              if (!snap.hasData) {
                return const Center(
                  child: CircularProgressIndicator(),
                );
              }

              final docs = snap.data!.docs;

              if (docs.isEmpty) {
                return const Center(
                  child: Text('Diga oi! 👋'),
                );
              }

              return ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final doc = docs[i];
                  final data = doc.data();

                  final authorId =
                      data['authorId']?.toString() ??
                          '';

                  return InkWell(
                    onLongPress: () =>
                        messageOptions(doc),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(
                        vertical: 4,
                      ),
                      child: Row(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          ProfileAvatar(
                            uid: authorId,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                InkWell(
                                  onTap: () => openProfile(
                                    context,
                                    authorId,
                                  ),
                                  child: Text(
                                    data['author']
                                            ?.toString() ??
                                        'Usuário',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight:
                                          FontWeight.bold,
                                      color: purple,
                                    ),
                                  ),
                                ),
                                if (data['replyToId'] != null)
                                  Container(
                                    margin:
                                        const EdgeInsets.only(
                                      top: 4,
                                      bottom: 4,
                                    ),
                                    padding:
                                        const EdgeInsets.all(
                                      7,
                                    ),
                                    decoration:
                                        const BoxDecoration(
                                      border: Border(
                                        left: BorderSide(
                                          color: purple,
                                          width: 3,
                                        ),
                                      ),
                                    ),
                                    child: Text(
                                      '${data['replyAuthor'] ?? 'Usuário'}: '
                                      '${data['replyText'] ?? ''}',
                                      maxLines: 2,
                                      overflow:
                                          TextOverflow.ellipsis,
                                      style:
                                          const TextStyle(
                                        fontSize: 12,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ),
                                Text(
                                  data['text']
                                          ?.toString() ??
                                      '',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: Colors.white,
                                  ),
                                ),
                                if (data['editedAt'] != null)
                                  const Text(
                                    '(editada)',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.white54,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        if (replyingId != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.reply,
                  color: purple,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Respondendo a $replyingAuthor: '
                    '$replyingText',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      replyingId = null;
                      replyingText = null;
                      replyingAuthor = null;
                    });
                  },
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                      hintText: 'Mensagem',
                      counterText: '',
                    ),
                    onSubmitted: (_) => send(),
                  ),
                ),
                IconButton(
                  onPressed: sending ? null : send,
                  icon: const Icon(
                    Icons.send,
                    color: purple,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// AMIGOS
// ============================================================

class FriendsPage extends StatefulWidget {
  final String uid;

  const FriendsPage({
    super.key,
    required this.uid,
  });

  @override
  State<FriendsPage> createState() =>
      _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  final username = TextEditingController();
  String? status;

  @override
  void dispose() {
    username.dispose();
    super.dispose();
  }

  Future<void> addFriend() async {
    final name = cleanName(username.text);

    if (name.isEmpty) return;

    try {
      final found = await FirebaseFirestore.instance
          .collection('users')
          .where(
            'username',
            isEqualTo: name,
          )
          .limit(1)
          .get();

      if (found.docs.isEmpty) {
        throw Exception('Usuário não encontrado');
      }

      final friend = found.docs.first;

      if (friend.id == widget.uid) {
        throw Exception(
          'Você não pode adicionar a si mesmo',
        );
      }

      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .collection('friends')
          .doc(friend.id)
          .set({
        'username': name,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        setState(() {
          status = 'Amigo adicionado!';
          username.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => status = '$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Amigos',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: username,
                  decoration: const InputDecoration(
                    hintText: 'Nome de usuário',
                  ),
                ),
              ),
              IconButton(
                onPressed: addFriend,
                icon: const Icon(
                  Icons.person_add,
                  color: purple,
                ),
              ),
            ],
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(status!),
            ),
          Expanded(
            child: StreamBuilder<
                QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(widget.uid)
                  .collection('friends')
                  .snapshots(),
              builder: (context, snap) {
                return ListView(
                  children: [
                    for (final doc in snap.data?.docs ?? [])
                      ListTile(
                        leading: ProfileAvatar(
                          uid: doc.id,
                        ),
                        onTap: () =>
                            openProfile(context, doc.id),
                        title: Text(
                          doc.data()['username']
                                  ?.toString() ??
                              '?',
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          const Text(
            'Toque em um amigo para abrir o perfil '
            'e enviar uma mensagem.',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
