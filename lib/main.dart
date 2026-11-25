import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:gal/gal.dart';
import 'package:file_saver/file_saver.dart';
import 'package:characters/characters.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/cupertino.dart';
import 'package:file_selector/file_selector.dart' as files;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
const bg = Color(0xFF111218), panel = Color(0xFF1C1D28), purple = Color(0xFF8B5CF6);
const avatarLimit = 8 * 1024 * 1024, bannerLimit = 15 * 1024 * 1024, attachmentLimit = 25 * 1024 * 1024;
const imageHost = 'ffxsvctvcsldumxnkiob.supabase.co';
final changedImage = ValueNotifier<Uri?>(null);
final db = FirebaseFirestore.instance;
final meowNavigator = GlobalKey<NavigatorState>();
final meowRouteObserver = RouteObserver<ModalRoute<dynamic>>();
final activeThread = ValueNotifier<String?>(null);
String userLabel(Map<String,dynamic> d) {
  final n=d['displayName']?.toString().trim()??'';
  return n.isNotEmpty?n:'Usuário';
}
// Public identity is independent of the permanent Firebase UID.
String meowSerial(Map<String,dynamic>? data) {
  final n=data?['serialId'];
  if(n is! int||n<1||n>99999999)return '';
  return n.toString().padLeft(8,'0');
}
String meowPublicId(Map<String,dynamic>? data) {
  final serial=meowSerial(data);
  return serial.isEmpty?'ID ainda não atribuído':'#$serial';
}
String privateLoginName(String uid) {
  final user=FirebaseAuth.instance.currentUser;
  if(user==null||user.uid!=uid)return '';
  final email=user.email??'';
  const suffix='@users.meow.invalid';
  return email.endsWith(suffix)?email.substring(0,email.length-suffix.length):'';
}
bool meowMentioned(Set<String> names, String uid, Map<String,dynamic>? data) {
  final serial=meowSerial(data);
  final legacy=privateLoginName(uid);
  return (serial.isNotEmpty&&names.contains('#$serial'))||
      (legacy.isNotEmpty&&names.contains(legacy));
}
Future<void> meowAccountAction(Map<String,dynamic> body) async {
  final uid=FirebaseAuth.instance.currentUser?.uid;
  final response=await http.post(Uri.https(imageHost,'/functions/v1/meow-contas'),
    headers:{...await authHeaders(),'Content-Type':'application/json'},
    body:jsonEncode(body)).timeout(const Duration(seconds:30));
  if(FirebaseAuth.instance.currentUser?.uid!=uid)throw Exception('Sessão alterada.');
  if(response.statusCode!=200)throw Exception('Serviço de contas indisponível (HTTP ${response.statusCode}).');
  final result=jsonDecode(response.body);
  if(result is! Map||result['ok']!=true)throw Exception('Não foi possível confirmar a operação.');
}
String currentPresence(Map<String,dynamic>? d) {
  final p=d?['presence']?.toString()??'offline';
  final t=d?['lastSeen'];
  if(p=='invisible'||t is! Timestamp||DateTime.now().difference(t.toDate())>const Duration(seconds:110))return 'offline';
  return presenceLabels.containsKey(p)?p:'offline';
}
Future<void> notifyMessage(String path) async {
  try {
    final r=await http.post(Uri.https(imageHost,'/functions/v1/meow-notificacoes'),headers:{...await authHeaders(),'Content-Type':'application/json'},body:jsonEncode({'messagePath':path})).timeout(const Duration(seconds:45));
    if(r.statusCode!=200)debugPrint('Meow FCM: HTTP ${r.statusCode}');
  }catch(e){debugPrint('Meow FCM indisponível: $e');}
}
Future<void> logoutMeow(BuildContext c) async {
  try {
    final uid=myUid; final f=FirebaseMessaging.instance;
    final token=await f.getToken();
    if(token!=null)await db.collection('users').doc(uid).collection('devices').doc(token).delete();
    try {await f.deleteToken();}catch(_){}
  }catch(e){if(c.mounted)notice(c,'Não foi possível desregistrar as notificações: $e');return;}
  PrivateMediaCache.clear();MeowStreams.clear();activeThread.value=null;
  meowNavigator.currentState?.popUntil((route)=>route.isFirst);
  await FirebaseAuth.instance.signOut();
}

// 0.7.0 hotfix: shared Firestore subscriptions, scoped to the authenticated session.
// Only keep the native listener while at least one visible consumer needs it.
class _MeowFeed<T> {
  final Stream<T> Function() source;
  final _clients = <MultiStreamController<T>>{};
  StreamSubscription<T>? _subscription;
  T? _last;
  bool _hasLast = false;
  int _epoch = 0;
  _MeowFeed(this.source);
  bool get idle => _clients.isEmpty;
  late final Stream<T> stream = Stream<T>.multi((client) {
    _clients.add(client);
    client.onCancel = () async {
      _clients.remove(client);
      if (_clients.isEmpty) {
        _epoch++;
        final old = _subscription;
        _subscription = null;
        _last = null;
        _hasLast = false;
        await old?.cancel();
      }
    };
    if (_hasLast) client.add(_last as T);
    if (_subscription != null) return;
    final generation = ++_epoch;
    _subscription = source().listen((value) {
      if (generation != _epoch) return;
      _last = value;
      _hasLast = true;
      for (final c in _clients.toList()) { c.add(value); }
    }, onError: (Object error, StackTrace stack) {
      if (generation != _epoch) return;
      _hasLast = false;
      _last = null;
      for (final c in _clients.toList()) { c.addError(error, stack); }
    }, onDone: () {
      if (generation != _epoch) return;
      _subscription = null;
      _last = null;
      _hasLast = false;
      for (final c in _clients.toList()) { c.close(); }
    });
  }, isBroadcast: true);
}
class MeowStreams {
  static final _documents = <Object, _MeowFeed<DocumentSnapshot<Map<String,dynamic>>>>{};
  static final _queries = <Object, _MeowFeed<QuerySnapshot<Map<String,dynamic>>>>{};
  static String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';
  static Stream<T> _get<T>(Map<Object,_MeowFeed<T>> entries, Object key, Stream<T> Function() source) {
    var feed = entries.remove(key);
    if (feed == null) {
      if (entries.length >= 512) {
        final idle = entries.entries.where((e) => e.value.idle).take(64).map((e) => e.key).toList();
        for (final k in idle) { entries.remove(k); }
      }
      feed = _MeowFeed<T>(source);
    }
    entries[key] = feed;
    return feed.stream;
  }
  static Stream<DocumentSnapshot<Map<String,dynamic>>> document(DocumentReference<Map<String,dynamic>> ref) =>
    _get(_documents, (_uid,ref.path), () => ref.snapshots());
  static Stream<QuerySnapshot<Map<String,dynamic>>> query(Query<Map<String,dynamic>> ref) =>
    _get(_queries, (_uid,ref), () => ref.snapshots());
  static void clear() { _documents.clear(); _queries.clear(); }
}
extension MeowDocumentStream on DocumentReference<Map<String,dynamic>> {
  Stream<DocumentSnapshot<Map<String,dynamic>>> meowSnapshots() => MeowStreams.document(this);
}
extension MeowQueryStream on Query<Map<String,dynamic>> {
  Stream<QuerySnapshot<Map<String,dynamic>>> meowSnapshots() => MeowStreams.query(this);
}
// TickerMode is also used to suspend streams in hidden tabs/panels. The inner
// StreamBuilder retains its snapshot while disconnected; reentry resumes live data.
class MeowStreamBuilder<T> extends StatelessWidget {
  final Stream<T>? stream;
  final AsyncWidgetBuilder<T> builder;
  const MeowStreamBuilder({super.key,required this.stream,required this.builder});
  @override Widget build(BuildContext context) => StreamBuilder<T>(
    stream: TickerMode.of(context) ? stream : null, builder:builder);
}

// Cache privado em memoria por sessao. Nunca persiste imagens privadas no disco.
// Compartilha requisicoes entre avatares repetidos e evita novos downloads ao navegar.
class PrivateMediaCache {
  static final _pending = <String, Future<Uint8List?>>{};
  static final _completed = <String, ({Uint8List bytes, DateTime time, Future<Uint8List?> future})>{};
  static final _generation = <String, int>{};
  static const int maxBytes = 40 * 1024 * 1024;
  static const Duration lifetime = Duration(minutes: 5);
  static int _usedBytes = 0;
  static int _session = 0;
  static String _key(Uri url) => '${FirebaseAuth.instance.currentUser?.uid ?? ''}|$url';
  static bool _valid(Uri url, String key, int generation, int session) =>
      _session == session && FirebaseAuth.instance.currentUser != null &&
      _key(url) == key && (_generation[key] ?? 0) == generation;

  static Future<Uint8List?> get(Uri url) {
    final key = _key(url);
    final entry = _completed.remove(key);
    if (entry != null) {
      if (DateTime.now().difference(entry.time) < lifetime) {
        _completed[key] = entry;
        return entry.future;
      }
      _usedBytes -= entry.bytes.lengthInBytes;
    }
    final existing = _pending[key];
    if (existing != null) return existing;
    final task = _download(url, key, _generation[key] ?? 0, _session);
    _pending[key] = task;
    task.whenComplete(() {
      if (identical(_pending[key], task)) _pending.remove(key);
    });
    return task;
  }

  static void _store(String key, Uint8List bytes) {
    final old = _completed.remove(key);
    if (old != null) _usedBytes -= old.bytes.lengthInBytes;
    if (bytes.isEmpty || bytes.lengthInBytes > maxBytes) return;
    while (_completed.isNotEmpty && _usedBytes + bytes.lengthInBytes > maxBytes) {
      _usedBytes -= _completed.remove(_completed.keys.first)!.bytes.lengthInBytes;
    }
    _completed[key] = (bytes: bytes, time: DateTime.now(), future: Future<Uint8List?>.value(bytes));
    _usedBytes += bytes.lengthInBytes;
  }

  static Future<Uint8List?> _download(Uri url, String key, int generation, int session) async {
    // Never persist a failed response as a successful or missing image.
    // Only repeat safe GETs on transient failures, never upload requests.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!_valid(url, key, generation, session)) return null;
      final client = http.Client();
      try {
        final headers = await authHeaders();
        if (!_valid(url, key, generation, session)) return null;
        final response = await client.get(url, headers: headers).timeout(const Duration(seconds: 20));
        if (!_valid(url, key, generation, session)) return null;
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          _store(key, response.bodyBytes);
          return response.bodyBytes;
        }
        debugPrint('Meow media: HTTP ${response.statusCode} em ${url.path}');
        if (response.statusCode != 429 && response.statusCode < 500) return null;
      } catch (e) {
        debugPrint('Meow media: falha no download (${url.path}): $e');
      } finally {
        client.close();
      }
      if (attempt == 0) await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return null;
  }

  static void invalidate(Uri url) {
    final key = _key(url);
    _generation[key] = (_generation[key] ?? 0) + 1;
    final old = _completed.remove(key);
    if (old != null) _usedBytes -= old.bytes.lengthInBytes;
    _pending.remove(key);
  }

  static void clear() {
    _session++;
    _generation.clear();
    _completed.clear();
    _pending.clear();
    _usedBytes = 0;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}

String get myUid => FirebaseAuth.instance.currentUser!.uid;
String cleanName(String s) => s.trim().toLowerCase();
String loginEmail(String s) => '${cleanName(s)}@users.meow.invalid';
void notice(BuildContext c, Object s) {
  if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$s')));
}
  Uri mediaUrl(String scope, String id, String slot) => Uri.https(imageHost, '/functions/v1/meow-imagens',
  {
    'scope':scope,
    'id':id,
    'slot':slot
}
);
// The meow-anexos Edge Function must be deployed separately. It must validate
// Firebase bearer tokens, membership, MIME type and the 25 MiB file limit.
Uri attachmentUrl(String id) => Uri.https(imageHost, '/functions/v1/meow-anexos', {
  'id':id
}
);
Future<Map<String, String>> authHeaders() async {
  final token = await FirebaseAuth.instance.currentUser?.getIdToken();
  if (token == null) throw Exception('Entre novamente no Meow.');
  return {
    'Authorization':'Bearer $token'
}
;
}
@pragma('vm:entry-point') Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // The OS displays notification payloads. Sending requires a trusted backend.
}
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const apiKey = String.fromEnvironment('FB_API_KEY');
  const appId = String.fromEnvironment('FB_APP_ID');
  const senderId = String.fromEnvironment('FB_SENDER_ID');
  const projectId = String.fromEnvironment('FB_PROJECT_ID');
  if ([apiKey, appId, senderId, projectId].any((s) => s.isEmpty)) {
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Configure o Firebase no GitHub Actions.')))));
    return;
}
  runApp(const MaterialApp(debugShowCheckedModeBanner:false, home: LoadingCat()));
  try {
      await Firebase.initializeApp(options: const FirebaseOptions(apiKey:apiKey, appId:appId, messagingSenderId:senderId,
    projectId:projectId
));
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    runApp(const MeowApp());
} catch (e) {
    runApp(MaterialApp(home: Scaffold(body: Center(child: Text('Erro ao iniciar: $e')))));
}
}

class MeowApp extends StatelessWidget {
  const MeowApp({
    super.key
}
);
    @override Widget build(BuildContext context) => MaterialApp(navigatorKey:meowNavigator,navigatorObservers:[meowRouteObserver],debugShowCheckedModeBanner:false, title:'Meow',
      theme: ThemeData.dark(useMaterial3:true).copyWith(pageTransitionsTheme:PageTransitionsTheme(builders:{TargetPlatform.android:FadeUpwardsPageTransitionsBuilder(),TargetPlatform.iOS:CupertinoPageTransitionsBuilder()}),scaffoldBackgroundColor:bg, colorScheme:ColorScheme.fromSeed(seedColor:purple,
    brightness:Brightness.dark
), appBarTheme:const AppBarTheme(backgroundColor:panel), inputDecorationTheme:InputDecorationTheme(filled:true,
    fillColor:panel, border:OutlineInputBorder(borderRadius:BorderRadius.circular(14))
),), home:StreamBuilder<User?>(stream:FirebaseAuth.instance.authStateChanges(), builder:(c, s) => s.connectionState == ConnectionState.waiting ? const LoadingCat() : s.data == null ? const LoginPage() : MeowIdentityGate(key:ValueKey(s.data!.uid),uid:s.data!.uid)),
);
}

// A newly authenticated account must receive a server-assigned identity before
// opening the chat. Existing provisioned profiles also work from the offline cache.
class MeowIdentityGate extends StatefulWidget {
  final String uid;
  const MeowIdentityGate({super.key,required this.uid});
  @override State<MeowIdentityGate> createState()=>_MeowIdentityGateState();
}
class _MeowIdentityGateState extends State<MeowIdentityGate> {
  late Future<void> ready;
  @override void initState(){super.initState();ready=prepare();}
  Future<void> prepare() async {
    final ref=db.collection('users').doc(widget.uid);
    final existing=await ref.get().timeout(const Duration(seconds:15));
    if(existing.exists&&meowSerial(existing.data()).isNotEmpty&&
       !(existing.data()??{}).containsKey('username'))return;
    await meowAccountAction({'action':'ensure'});
    final updated=await ref.get(const GetOptions(source:Source.server)).timeout(const Duration(seconds:15));
    if(!updated.exists||meowSerial(updated.data()).isEmpty||
       (updated.data()??{}).containsKey('username'))throw Exception('Cadastro público ainda não migrado.');
  }
  @override Widget build(BuildContext c)=>FutureBuilder<void>(future:ready,builder:(c,s){
    if(s.connectionState!=ConnectionState.done)return const LoadingCat();
    if(!s.hasError)return const SocialHome();
    return Scaffold(body:Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(
      mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.cloud_off,size:48),
      const SizedBox(height:12),const Text('Não foi possível preparar seu ID Meow.',textAlign:TextAlign.center),
      const Text('Sua conta continua existente. Verifique a conexão e tente novamente.',textAlign:TextAlign.center),
      const SizedBox(height:12),FilledButton(onPressed:()=>setState(()=>ready=prepare()),child:const Text('Tentar novamente')),
      TextButton(onPressed:()async{PrivateMediaCache.clear();MeowStreams.clear();await FirebaseAuth.instance.signOut();},child:const Text('Sair da conta'))
    ]))));
  });
}
class LoadingCat extends StatelessWidget {
  const LoadingCat({super.key});
  @override Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Colors.black,
    body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Image(image: AssetImage('assets/meow_foreground.png'), width: 180, height: 180),
      SizedBox(height: 20),
      Text('você é um testador Beta!', textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white, fontSize: 16)),
    ])),
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key
}
);
  @override State<LoginPage> createState()=>_LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final name=TextEditingController(),
  password=TextEditingController();
  bool register=false,
  busy=false;
  @override void dispose(){
    name.dispose();
    password.dispose();
    super.dispose();
}
  Future<void> submit() async {
    final n=cleanName(name.text);
    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(n)) {
      notice(context, 'Usuário: 3 a 20 letras, números ou _.');
      return;
}
    if(password.text.length<8){
      notice(context, 'A senha precisa de 8 caracteres.');
      return;
}
    setState(()=>busy=true);
    try {
      if(register){
        await FirebaseAuth.instance.createUserWithEmailAndPassword(email:loginEmail(n), password:password.text);
        // MeowIdentityGate provisions the public profile through the trusted backend.
        // Never store the login name in a publicly readable Firestore document.
}else{
        await FirebaseAuth.instance.signInWithEmailAndPassword(email:loginEmail(n), password:password.text);
}
}catch(e){
      if(mounted)notice(context, e);
}
    if(mounted)setState(()=>busy=false);
}
    @override Widget build(BuildContext c)=>Scaffold(body:Center(child:SingleChildScrollView(padding:const EdgeInsets.all(24),
      child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:420), child:Column(mainAxisSize:MainAxisSize.min,
        children:[const Image(image:AssetImage('assets/meow_foreground.png'), width:88, height:88), const SizedBox(height:18), Text(register?'Criar conta Meow':'Entrar no Meow',
      style:const TextStyle(fontSize:24, fontWeight:FontWeight.bold)
), const SizedBox(height:22), TextField(controller:name, decoration:const InputDecoration(labelText:'Usuário')),
        const SizedBox(height:12), TextField(controller:password, obscureText:true, decoration:const InputDecoration(labelText:'Senha')),
        const SizedBox(height:14), FilledButton(onPressed:busy?null:submit, child:Text(busy?'Aguarde...':register?'Criar conta':'Entrar')),
        TextButton(onPressed:()=>setState(()=>register=!register), child:Text(register?'Já tenho conta':'Criar conta')),
]
))
)));
}

// Restore the 0.7.0 image decoder. Original bytes and GIF frames stay intact.
// Keep the stable futures, private byte cache and other UI optimizations.
Widget meowPreview(BuildContext context, Uint8List bytes, {required double width,required double height,required BoxFit fit,ImageErrorWidgetBuilder? errorBuilder,bool gapless=true}) {
  return Image.memory(bytes,fit:fit,gaplessPlayback:gapless,errorBuilder:errorBuilder);
}
class PrivateImage extends StatefulWidget {
  final String scope,
  id,
  slot;
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
    this.borderRadius
}
);
  Uri get url=>mediaUrl(scope, id, slot);
  @override State<PrivateImage> createState()=>_PrivateImageState();
}

class _PrivateImageState extends State<PrivateImage> {
  late Future<Uint8List?> future;
  Future<Uint8List?> fetch() => PrivateMediaCache.get(widget.url);
  void refresh(){
    if(changedImage.value==widget.url&&mounted){
      setState(()=>future=fetch());
    }
}
  @override void initState(){
    super.initState();
    future=fetch();
    changedImage.addListener(refresh);
}
  @override void didUpdateWidget(covariant PrivateImage old){
    super.didUpdateWidget(old);
    if(old.url!=widget.url)future=fetch();
}
  @override void dispose(){
    changedImage.removeListener(refresh);
    super.dispose();
}
  @override Widget build(BuildContext c){
    final banner=widget.slot=='banner';
      return SizedBox(width:widget.width??(banner?double.infinity:widget.size), height:widget.size, child:ClipRRect(borderRadius:widget.borderRadius??BorderRadius.circular(banner?8:widget.size),
      child:FutureBuilder<Uint8List?>(future:future, builder:(c, s){
          final placeholder=ColoredBox(color:panel, child:Center(child:Icon(banner?Icons.landscape:widget.scope=='server'?Icons.groups:Icons.person,
        color:Colors.white54, size:banner?38:widget.size*.5
)));
          return s.data==null?placeholder:meowPreview(c,s.data!,width:widget.width??widget.size,height:widget.size,fit:BoxFit.cover,errorBuilder:(c,
        e, st
){ debugPrint('Meow: falha ao decodificar imagem: $e'); return placeholder; });
}
)
));
}
}

class ChangeImage extends StatefulWidget {
  final String scope,
  id,
  slot,
  label;
  final bool iconOnly;
  const ChangeImage(this.scope, this.id, this.slot, this.label, {
    super.key,
    this.iconOnly=false
}
);
  @override State<ChangeImage> createState()=>_ChangeImageState();
}

class _ChangeImageState extends State<ChangeImage> {
  bool busy=false;
  Future<void> choose() async {
    if(busy)return;
    setState(()=>busy=true);
    try{
        final source=await showModalBottomSheet<String>(context:context, builder:(c)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,
          children:[ListTile(leading:const Icon(Icons.photo_library), title:const Text('Galeria'), onTap:()=>Navigator.pop(c,
        'gallery'
)), ListTile(leading:const Icon(Icons.folder), title:const Text('Arquivos / GIF original'), onTap:()=>Navigator.pop(c,
        'files'
)),]
)));
      if(!mounted || source==null)return;
        final f=source=='gallery'?await ImagePicker().pickImage(source:ImageSource.gallery, requestFullMetadata:false):await files.openFile(acceptedTypeGroups:const [files.XTypeGroup(label:'Imagens',
      extensions:['jpg', 'jpeg', 'png', 'webp', 'gif']
)]);
      if(f==null||!mounted)return;
      final limit=widget.slot=='avatar'?avatarLimit:bannerLimit;
      if(await f.length()>limit)throw Exception('Limite de ${limit~/1048576} MiB.');
        // Preserva o tipo original do arquivo (inclusive GIF animado).
      final extension = f.name.split('.').last.toLowerCase();
      const imageMime = <String, String>{
        'gif': 'image/gif',
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'webp': 'image/webp',
      };
      var bytes=await f.readAsBytes();
      var mime=imageMime[extension]??'application/octet-stream';
      if(!mounted)return;
      var edit=true;
      if(extension=='gif'||extension=='webp'){
        final codec=await ui.instantiateImageCodec(bytes);final animated=codec.frameCount>1;codec.dispose();
        if(!mounted)return;
        if(animated){final choice=await showDialog<String>(context:context,builder:(c)=>AlertDialog(title:const Text('Imagem animada'),content:const Text('Enviar o original preserva a animação. Recortar cria uma imagem estática.'),actions:[TextButton(onPressed:()=>Navigator.pop(c,'cancel'),child:const Text('Cancelar')),TextButton(onPressed:()=>Navigator.pop(c,'crop'),child:const Text('Recortar')),FilledButton(onPressed:()=>Navigator.pop(c,'original'),child:const Text('Enviar original'))]));if(choice==null||choice=='cancel')return;edit=choice=='crop';}
      }
      if(edit){
        if(!mounted)return;
        final result=await Navigator.push<Uint8List>(context,MaterialPageRoute(builder:(_)=>MeowCropPage(bytes:bytes,aspect:widget.slot=='avatar'?1.0:widget.slot=='banner'?3.0:0.75,circle:widget.slot=='avatar')));
        if(result==null||!mounted)return;
        if(!identical(result,bytes))mime='image/png';
        bytes=result;
      }
      if(bytes.length>limit)throw Exception('Imagem acima do limite após edição.');
      final headers = await authHeaders();
      headers['Content-Type'] = mime;
      final r=await http.put(mediaUrl(widget.scope, widget.id, widget.slot), headers:headers,
      body:bytes
).timeout(const Duration(seconds:120));
      if(r.statusCode!=200)throw Exception('Falha ao atualizar imagem (HTTP ${r.statusCode}): ${r.body}');
      final updatedUrl=mediaUrl(widget.scope,widget.id,widget.slot);
      PrivateMediaCache.invalidate(updatedUrl);
      changedImage.value=null;
      changedImage.value=updatedUrl;
      if(widget.scope=='profile'&&widget.slot=='banner')await db.collection('users').doc(widget.id).update({'bannerHidden':false});
      if(widget.scope=='profile'&&widget.slot=='background')await db.collection('users').doc(widget.id).update({'backgroundEnabled':true});
      if(mounted)notice(context, 'Imagem atualizada!');
}catch(e){
      if(mounted)notice(context, e);
}finally{
      if(mounted)setState(()=>busy=false);
}
}
    @override Widget build(BuildContext c)=>widget.iconOnly?IconButton.filledTonal(onPressed:busy?null:choose,
  tooltip:widget.label, icon:Icon(busy?Icons.hourglass_top:Icons.camera_alt)
):OutlinedButton.icon(onPressed:busy?null:choose, icon:const Icon(Icons.image), label:Text(busy?'Enviando...':widget.label));
}
const presenceLabels={
  'online':'Online',
  'idle':'Ausente',
  'dnd':'Não perturbe',
  'invisible':'Invisível'
}
;
Color presenceColor(String p)=>switch(p){
  'online'=>Colors.greenAccent,
  'idle'=>Colors.amber,
  'dnd'=>Colors.redAccent,
  _=>Colors.grey
}
;

class PresenceDot extends StatelessWidget {
  final String uid;
  const PresenceDot({super.key,required this.uid});
  @override Widget build(BuildContext c)=>MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
    stream:db.collection('users').doc(uid).meowSnapshots(),builder:(c,s)=>_PresenceGlyph(data:s.data?.data()));
}
class _PresenceGlyph extends StatefulWidget {
  final Map<String,dynamic>? data;
  const _PresenceGlyph({required this.data});
  @override State<_PresenceGlyph> createState()=>_PresenceGlyphState();
}
class _PresenceGlyphState extends State<_PresenceGlyph>{
  Timer? timer;
  void schedule(){
    timer?.cancel();timer=null;
    if(!TickerMode.of(context)||currentPresence(widget.data)=='offline')return;
    final t=widget.data?['lastSeen'];
    if(t is! Timestamp)return;
    final remaining=t.toDate().add(const Duration(seconds:110,milliseconds:50)).difference(DateTime.now());
    if(remaining>Duration.zero)timer=Timer(remaining,(){if(mounted)setState((){});});
  }
  @override void didChangeDependencies(){super.didChangeDependencies();schedule();}
  @override void didUpdateWidget(covariant _PresenceGlyph old){super.didUpdateWidget(old);if(old.data?['lastSeen']!=widget.data?['lastSeen']||old.data?['presence']!=widget.data?['presence'])schedule();}
  @override void dispose(){timer?.cancel();super.dispose();}
  @override Widget build(BuildContext c)=>Container(width:13,height:13,decoration:BoxDecoration(color:presenceColor(currentPresence(widget.data)),shape:BoxShape.circle,border:Border.all(color:bg,width:2)));
}
class ProfileAvatar extends StatelessWidget {
  final String uid;
  final double size;
  const ProfileAvatar({
    super.key,
    required this.uid,
    this.size=40
}
);
    @override Widget build(BuildContext c)=>InkWell(onTap:()=>openProfile(c, uid), child:Stack(clipBehavior:Clip.none,
      children:[PrivateImage(scope:'profile', id:uid, slot:'avatar', size:size), Positioned(right:0, bottom:0,
    child:PresenceDot(uid:uid)
)]
));
}
Future<void> openProfile(BuildContext context, String uid) async {
  if(uid.isEmpty)return;
    final action=await showModalBottomSheet<String>(context:context, isScrollControlled:true, useSafeArea:true, backgroundColor:panel,
      builder:(c)=>DraggableScrollableSheet(expand:false, initialChildSize:.82, maxChildSize:.96, builder:(c,
    scroll
)=>ProfilePage(uid:uid, expanded:true, scrollController:scroll))
);
 if(action=='dm' && context.mounted) await openDm(context,uid);
}


Future<void> toggleFollow(String target, bool following) async {
  final mine = db.collection('users').doc(myUid).collection('following').doc(target);
  final theirs = db.collection('users').doc(target).collection('followers').doc(myUid);
  final batch = db.batch();
  if (following) { batch.delete(mine); batch.delete(theirs); }
  else { batch.set(mine, {'createdAt': FieldValue.serverTimestamp()}); batch.set(theirs, {'createdAt': FieldValue.serverTimestamp()}); }
  await batch.commit();
}

class RelationshipListPage extends StatelessWidget {
  final String uid, kind;
  const RelationshipListPage({super.key, required this.uid, required this.kind});
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(kind=='followers'?'Seguidores':kind=='following'?'Seguindo':'Amigos')),
    body: MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(
      stream: db.collection('users').doc(uid).collection(kind=='friends'?'following':kind).meowSnapshots(),
      builder: (context,s) {
        if(s.hasError)return Center(child:Text('Erro: ${s.error}'));
        if(!s.hasData)return const Center(child:CircularProgressIndicator());
        final docs=s.data!.docs;
        if(kind=='friends')return MutualFriendsList(uid:uid);
        if(kind!='friends')return ListView(children:[for(final d in docs) ListTile(
          leading: ProfileAvatar(uid:d.id), title: UserDisplayName(uid:d.id),
          onTap:()=>openProfile(context,d.id))]);
        return ListView(children:[for(final d in docs) MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
          stream:db.collection('users').doc(d.id).collection('following').doc(uid).meowSnapshots(),
          builder:(context,other)=>other.data?.exists==true?ListTile(
            leading:ProfileAvatar(uid:d.id),title:UserDisplayName(uid:d.id),
            onTap:()=>openProfile(context,d.id)):const SizedBox.shrink())]);
      }));
}
class UserDisplayName extends StatelessWidget {
  final String uid;
  const UserDisplayName({super.key,required this.uid});
  @override Widget build(BuildContext context)=>MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
    stream:db.collection('users').doc(uid).meowSnapshots(),
    builder:(context,s){final d=s.data?.data()??{};return Text(userLabel(d));});
}
class FollowButton extends StatelessWidget {
  final String target;
  const FollowButton({super.key,required this.target});
  @override Widget build(BuildContext context)=>MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
    stream:db.collection('users').doc(myUid).collection('following').doc(target).meowSnapshots(),
    builder:(context,s)=>FilledButton.icon(
      onPressed:()=>toggleFollow(target,s.data?.exists==true).catchError((Object e){if(context.mounted)notice(context,e);}),
      icon:Icon(s.data?.exists==true?Icons.person_remove:Icons.person_add),
      label:Text(s.data?.exists==true?'Deixar de seguir':'Seguir')));
}
class MeowMutualChecks {
 static final _cached=Expando<Future<List<String>>>('meowMutual');
 static final _empty=Future<List<String>>.value(<String>[]);
 static Future<List<String>> ids(String uid,QuerySnapshot<Map<String,dynamic>>? snapshot){
   if(snapshot==null)return _empty;
   return _cached[snapshot]??=Future.wait(snapshot.docs.map((d)=>db.collection('users').doc(d.id).collection('following').doc(uid).get())).then((checks)=>checks.where((d)=>d.exists).map((d)=>d.reference.parent.parent!.id).toList());
 }
}
class RelationshipCounters extends StatelessWidget {
  final String uid;
  const RelationshipCounters({super.key,required this.uid});
  @override Widget build(BuildContext context)=>Row(children:[
    for(final kind in ['followers','following','friends']) Expanded(child:MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(
      stream:db.collection('users').doc(uid).collection(kind=='friends'?'following':kind).meowSnapshots(),
      builder:(context,s){
        if(kind=='friends')return FutureBuilder<List<String>>(future: MeowMutualChecks.ids(uid,s.data),builder:(context,c)=>_counter(context,kind,c.data?.length??0));
        return _counter(context,kind,s.data?.docs.length??0);
      }))]);
  Widget _counter(BuildContext c,String kind,int count)=>TextButton(
    onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>RelationshipListPage(uid:uid,kind:kind))),
    child:Column(children:[Text('$count',style:const TextStyle(fontWeight:FontWeight.bold)),
      Text(kind=='followers'?'Seguidores':kind=='following'?'Seguindo':'Amigos',style:const TextStyle(fontSize:11))]));
  Future<int> _mutualCount(String uid,List<QueryDocumentSnapshot<Map<String,dynamic>>> docs)async{
    var count=0;
    for(final d in docs){
      if((await db.collection('users').doc(d.id).collection('following').doc(uid).get()).exists)count++;
    }
    return count;
  }
}

class MeowIdLabel extends StatelessWidget {
 final Map<String,dynamic> data;final Color ink;
 const MeowIdLabel({super.key,required this.data,required this.ink});
 @override Widget build(BuildContext c){final serial=meowSerial(data);return Row(mainAxisSize:MainAxisSize.min,children:[
   Text(meowPublicId(data),style:TextStyle(color:ink.withOpacity(.75))),
   if(serial.isNotEmpty)IconButton(tooltip:'Copiar ID',visualDensity:VisualDensity.compact,iconSize:16,
     constraints:const BoxConstraints(minWidth:36,minHeight:36),padding:EdgeInsets.zero,color:ink.withOpacity(.75),
     onPressed:()async{await Clipboard.setData(ClipboardData(text:serial));if(c.mounted)notice(c,'ID copiado!');},icon:const Icon(Icons.copy))
 ]);}
}
class MeowBadgeDefinition {
 final String id,title,description;final IconData icon;final Color color;
 const MeowBadgeDefinition(this.id,this.title,this.description,this.icon,this.color);
}
const meowBadgeDefinitions=[
 MeowBadgeDefinition('developer','Desenvolvedor','Participa do desenvolvimento do Meow.',Icons.code,Color(0xFFA78BFA)),
 MeowBadgeDefinition('beta_tester','Testador Beta','Participou dos testes da versão Beta.',Icons.science_outlined,Color(0xFF60A5FA)),
 MeowBadgeDefinition('bug_hunter','Caçador de Bugs','Contribuiu identificando problemas no Meow.',Icons.bug_report_outlined,Color(0xFF4ADE80)),
];
Set<String> meowBadges(Map<String,dynamic> data){
 final raw=data['badges'];
 return raw is List?raw.whereType<String>().where((id)=>meowBadgeDefinitions.any((b)=>b.id==id)).toSet():<String>{};
}
class MeowProfileBadges extends StatelessWidget {
 final Map<String,dynamic> data;final Color background,ink;
 const MeowProfileBadges({super.key,required this.data,required this.background,required this.ink});
 @override Widget build(BuildContext c){
   final ids=meowBadges(data);if(ids.isEmpty)return const SizedBox.shrink();
   return Container(padding:const EdgeInsets.symmetric(horizontal:6,vertical:2),
     decoration:BoxDecoration(color:const Color(0xD91B1B24),borderRadius:BorderRadius.circular(18)),
     child:Wrap(alignment:WrapAlignment.center,crossAxisAlignment:WrapCrossAlignment.center,children:[
       for(final badge in meowBadgeDefinitions)if(ids.contains(badge.id))
         IconButton(tooltip:badge.title,iconSize:22,visualDensity:VisualDensity.compact,
           constraints:const BoxConstraints(minWidth:36,minHeight:36),padding:const EdgeInsets.all(5),
           icon:Icon(badge.icon,color:badge.color),onPressed:()=>showDialog<void>(context:c,builder:(d)=>AlertDialog(
             icon:Icon(badge.icon,color:badge.color,size:36),title:Text(badge.title),content:Text(badge.description),
             actions:[TextButton(onPressed:()=>Navigator.pop(d),child:const Text('Fechar'))])))
     ]));
 }
}
class MeowAdminEntry extends StatefulWidget {
 const MeowAdminEntry({super.key});
 @override State<MeowAdminEntry> createState()=>_MeowAdminEntryState();
}
class _MeowAdminEntryState extends State<MeowAdminEntry> {
 late final Future<bool> allowed;
 @override void initState(){super.initState();allowed=check();}
 Future<bool> check()async{
  try{final token=await FirebaseAuth.instance.currentUser?.getIdTokenResult();return token?.claims?['meowAdmin']==true;}catch(_){return false;}
 }
 @override Widget build(BuildContext c)=>FutureBuilder<bool>(future:allowed,builder:(c,s)=>s.data==true?
   ListTile(leading:const Icon(Icons.verified_user_outlined),title:const Text('Gerenciar insígnias'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const MeowBadgeAdminPage()))):const SizedBox.shrink());
}
class MeowBadgeAdminPage extends StatefulWidget {
 const MeowBadgeAdminPage({super.key});
 @override State<MeowBadgeAdminPage> createState()=>_MeowBadgeAdminPageState();
}
class _MeowBadgeAdminPageState extends State<MeowBadgeAdminPage> {
 final search=TextEditingController();
 DocumentSnapshot<Map<String,dynamic>>? target;
 Set<String> selected={};bool busy=false;
 @override void dispose(){search.dispose();super.dispose();}
 Future<void> find()async{
  if(busy)return;
  final raw=search.text.trim().replaceFirst('#','');
  if(!RegExp(r'^[0-9]{1,8}$').hasMatch(raw)){notice(context,'Informe o ID numérico da conta.');return;}
  setState((){busy=true;target=null;selected={};});
  try{final matches=await meowFindUsers(raw);if(!mounted)return;
   if(matches.isEmpty){notice(context,'Conta não encontrada.');return;}
   setState((){target=matches.first;selected=meowBadges(matches.first.data());});
  }catch(_){if(mounted)notice(context,'Não foi possível buscar a conta.');}
  finally{if(mounted)setState(()=>busy=false);}
 }
 Future<void> save()async{
  final account=target;if(account==null||busy)return;
  setState(()=>busy=true);
  try{
   await meowAccountAction({'action':'setBadges','targetUid':account.id,'badges':selected.toList()});
   final updated=await account.reference.get(const GetOptions(source:Source.server));
   if(!mounted)return;
   setState((){target=updated;selected=meowBadges(updated.data()??{});});
   notice(context,'Insígnias atualizadas.');
  }catch(_){if(mounted)notice(context,'Não foi possível alterar as insígnias. Confira as permissões e a conexão.');}
  finally{if(mounted)setState(()=>busy=false);}
 }
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Gerenciar insígnias')),body:ListView(padding:const EdgeInsets.all(16),children:[
   TextField(controller:search,enabled:!busy,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'ID Meow'),onSubmitted:(_)=>find()),
   const SizedBox(height:8),FilledButton(onPressed:busy?null:find,child:const Text('Buscar conta')),
   if(target!=null)...[const SizedBox(height:12),ListTile(leading:ProfileAvatar(uid:target!.id),title:Text(userLabel(target!.data()??{})),subtitle:Text(meowPublicId(target!.data()))),
    for(final b in meowBadgeDefinitions)CheckboxListTile(secondary:Icon(b.icon,color:b.color),title:Text(b.title),subtitle:Text(b.description),value:selected.contains(b.id),onChanged:busy?null:(v)=>setState((){if(v==true){selected.add(b.id);}else{selected.remove(b.id);}})),
    FilledButton(onPressed:busy?null:save,child:const Text('Salvar alterações'))],
   if(busy)const Padding(padding:EdgeInsets.all(12),child:LinearProgressIndicator())]));
}
class ProfilePage extends StatelessWidget {
  final String uid; final bool expanded; final ScrollController? scrollController;
  const ProfilePage({super.key,required this.uid,this.expanded=false,this.scrollController});
  @override Widget build(BuildContext c)=>MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(uid).meowSnapshots(),builder:(c,s){
    if(s.hasError)return const Center(child:Text('Perfil indisponível.'));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    final d=s.data!.data()??{}; final own=uid==FirebaseAuth.instance.currentUser?.uid;
    final base=meowColor(d['themeColorA'],panel);final end=d['themeGradient']==true?meowColor(d['themeColorB'],base):base;
    final ink=d['backgroundEnabled']==true?Colors.white:Color.lerp(base,end,.5)!.computeLuminance()>.42?Colors.black:Colors.white;
    final accent=Color.lerp(base,ink,.22)!;final cardColor=Color.lerp(base,ink,.09)!.withOpacity(.88);
    final presence=currentPresence(d);
    return Theme(data:Theme.of(c).copyWith(textTheme:Theme.of(c).textTheme.apply(bodyColor:ink,displayColor:ink),colorScheme:Theme.of(c).colorScheme.copyWith(primary:ink,onPrimary:base,surface:cardColor,onSurface:ink)),child:Container(decoration:BoxDecoration(gradient:profileGradient(d)),child:Stack(children:[
      if(d['backgroundEnabled']==true)Positioned.fill(child:ProfileBackground(uid:uid)),
      ListView(controller:scrollController,padding:EdgeInsets.zero,children:[
        Stack(alignment:Alignment.topCenter,children:[
          if(d['bannerHidden']!=true)Positioned.fill(child:PrivateImage(scope:'profile',id:uid,slot:'banner',size:244,borderRadius:BorderRadius.zero)),
          Positioned.fill(child:DecoratedBox(decoration:BoxDecoration(gradient:LinearGradient(begin:Alignment.topCenter,end:Alignment.bottomCenter,colors:[Colors.transparent,Colors.black.withOpacity(.68)])))),
          Padding(padding:const EdgeInsets.fromLTRB(12,28,12,14),child:ConstrainedBox(constraints:const BoxConstraints(minHeight:202),child:Column(mainAxisAlignment:MainAxisAlignment.end,children:[
            Container(padding:const EdgeInsets.all(3),decoration:BoxDecoration(color:base,shape:BoxShape.circle),child:Stack(clipBehavior:Clip.none,children:[PrivateImage(scope:'profile',id:uid,slot:'avatar',size:84),Positioned(right:2,bottom:2,child:PresenceDot(uid:uid))])),
            const SizedBox(height:6),Text(userLabel(d),textAlign:TextAlign.center,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:25,fontWeight:FontWeight.bold,color:Colors.white)),
            Wrap(alignment:WrapAlignment.center,crossAxisAlignment:WrapCrossAlignment.center,spacing:5,children:[MeowIdLabel(data:d,ink:Colors.white),if((d['pronouns']?.toString()??'').isNotEmpty)Text(d['pronouns'].toString(),style:const TextStyle(color:Colors.white70,fontSize:12)),MeowProfileBadges(data:d,background:cardColor,ink:Colors.white)]),
            Row(mainAxisAlignment:MainAxisAlignment.center,children:[Icon(Icons.circle,size:9,color:presenceColor(presence)),const SizedBox(width:6),Text(presenceLabels[presence]??'Offline',style:const TextStyle(color:Colors.white70))]),
          ]))),
        ]),
        Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          if((d['customStatus']?.toString()??'').isNotEmpty)Padding(padding:const EdgeInsets.only(bottom:10),child:Text(d['customStatus'].toString(),textAlign:TextAlign.center)),
          Container(decoration:BoxDecoration(color:cardColor,borderRadius:BorderRadius.circular(15),border:Border.all(color:accent)),padding:const EdgeInsets.symmetric(vertical:8),child:RelationshipCounters(uid:uid)),
          const SizedBox(height:12),
          if(own)FilledButton.icon(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>EditProfilePage(uid:uid))),icon:const Icon(Icons.edit),label:const Text('Editar perfil e status'))
          else Row(children:[Expanded(child:FollowButton(target:uid)),const SizedBox(width:8),Expanded(flex:2,child:FilledButton.icon(onPressed:()async{if(expanded){Navigator.pop(c,'dm');}else{await openDm(c,uid);}},icon:const Icon(Icons.message),label:const Text('Enviar mensagem')))]),
          const SizedBox(height:8),MeowProfileSections(key:ValueKey(uid),uid:uid,data:d,cardColor:cardColor,ink:ink),
          if(own&&!expanded)TextButton.icon(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const AppSettingsPage())),icon:const Icon(Icons.settings),label:const Text('Configurações do aplicativo')),
        ])),
      ]),
    ])));
  });
}
class MeowProfileSections extends StatefulWidget {
 final String uid;final Map<String,dynamic> data;final Color cardColor,ink;
 const MeowProfileSections({super.key,required this.uid,required this.data,required this.cardColor,required this.ink});
 @override State<MeowProfileSections> createState()=>_MeowProfileSectionsState();
}
class _MeowProfileSectionsState extends State<MeowProfileSections>{
 int section=0;
 @override Widget build(BuildContext c)=>Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
   Row(children:[for(var i=0;i<3;i++)Expanded(child:TextButton(onPressed:(){setState(()=>section=i);},child:Column(children:[Text(['Sobre','Amigos','Servidores'][i],style:TextStyle(fontWeight:section==i?FontWeight.bold:FontWeight.normal,color:widget.ink)),const SizedBox(height:4),Container(height:2,color:section==i?purple:Colors.transparent)])))]),const Divider(height:1),const SizedBox(height:12),
   if(section==0)...[const Text('Sobre mim',style:TextStyle(fontWeight:FontWeight.bold)),const SizedBox(height:6),Text((widget.data['bio']?.toString()??'').isEmpty?'Sem biografia.':widget.data['bio'].toString()),const SizedBox(height:16),FriendsPreview(uid:widget.uid,background:widget.cardColor,ink:widget.ink),const SizedBox(height:16),Text(widget.uid==myUid?'Meus servidores':'Servidores em comum',style:const TextStyle(fontWeight:FontWeight.bold)),MeowCommonServers(uid:widget.uid)]
   else if(section==1)...[FriendsPreview(uid:widget.uid,background:widget.cardColor,ink:widget.ink),TextButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>RelationshipListPage(uid:widget.uid,kind:'friends'))),child:const Text('Ver todos os amigos'))]
   else ...[Text(widget.uid==myUid?'Meus servidores':'Servidores em comum',style:const TextStyle(fontWeight:FontWeight.bold)),MeowCommonServers(uid:widget.uid)],
 ]);
}
class MeowCommonServers extends StatelessWidget {
 final String uid;const MeowCommonServers({super.key,required this.uid});
 @override Widget build(BuildContext c)=>MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('servers').where('members',arrayContains:myUid).meowSnapshots(),builder:(c,s){
   if(s.hasError)return const Text('Servidores indisponíveis.');if(!s.hasData)return const Center(child:CircularProgressIndicator());
   final matches=s.data!.docs.where((d)=>d.data()['deleting']!=true&&(d.data()['members'] is List)&&(d.data()['members'] as List).contains(uid)).toList();
   if(matches.isEmpty)return const Padding(padding:EdgeInsets.symmetric(vertical:12),child:Text('Nenhum servidor.'));
   return Column(children:[for(final d in matches)ListTile(contentPadding:EdgeInsets.zero,leading:PrivateImage(scope:'server',id:d.id,slot:'avatar',size:40),title:Text(d.data()['name']?.toString()??'Servidor'))]);
 });
}
class AppSettingsPage extends StatelessWidget {
  const AppSettingsPage({super.key});
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Configurações')),
    body:ListView(children:[
      const Padding(padding:EdgeInsets.all(20),child:MeowTitle()),
      ListTile(leading:const Icon(Icons.person),title:const Text('Conta'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Conta')),body:ListView(children:[
        ListTile(title:const Text('Nome de usuário (login)'),subtitle:SelectableText(privateLoginName(myUid)),leading:const Icon(Icons.lock_outline)),
        ListTile(title:const Text('Editar perfil'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>EditProfilePage(uid:myUid)))),
        ListTile(title:const Text('Alterar senha'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const ChangePasswordPage()))), ListTile(title:const Text('Sair da conta'),onTap:()=>logoutMeow(c))]))))),
      const MeowAdminEntry(),
      ListTile(leading:const Icon(Icons.notifications),title:const Text('Notificações'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const NotificationSettingsPage()))),
      ListTile(leading:const Icon(Icons.storage),title:const Text('Armazenamento'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Armazenamento')),body:ListTile(title:const Text('Limpar cache de imagens'),onTap:(){PrivateMediaCache.clear();notice(c,'Cache limpo.');}))))),
      ListTile(leading:const Icon(Icons.info),title:const Text('Sobre o Meow'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Sobre o Meow')),body:const Center(child:MeowTitle()))))),
    ]));
}
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});
  @override State<NotificationSettingsPage> createState()=>_NotificationSettingsPageState();
}
class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Notificações')),body:MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(myUid).collection('preferences').doc('notifications').meowSnapshots(),builder:(c,s){
    final d=s.data?.data()??{};final enabled=d['enabled']!=false;
    return ListView(children:[SwitchListTile(title:const Text('Notificações da conta'),value:enabled,onChanged:(v)async{try{await db.collection('users').doc(myUid).collection('preferences').doc('notifications').set({'enabled':v},SetOptions(merge:true));if(v)await FirebaseMessaging.instance.requestPermission();}catch(e){if(c.mounted)notice(c,e);}}),const ListTile(title:Text('Silenciar conversas'),subtitle:Text('Use o sino no cabeçalho de um canal ou DM.')),const ListTile(title:Text('Privacidade'),subtitle:Text('O conteúdo das mensagens fica oculto na notificação do sistema.'))]);
  }));
}
class EditProfilePage extends StatefulWidget {
  final String uid;
  const EditProfilePage({
    super.key,
    required this.uid
}
);
  @override State<EditProfilePage> createState()=>_EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final name=TextEditingController(),
  pronouns=TextEditingController(),
  bio=TextEditingController(),
  custom=TextEditingController();
  String presence='online';
  bool loaded=false,
  busy=false;
  @override void dispose(){
    name.dispose();
    pronouns.dispose();
    bio.dispose();
    custom.dispose();
    super.dispose();
}
  Future<void> save()async{
    if(name.text.trim().length>15){notice(context, 'Máximo de 15 caracteres no nome.');return;}
    setState(()=>busy=true);
    try{
      await db.collection('users').doc(widget.uid).update({
        'displayName':name.text.trim(),
        'pronouns':pronouns.text.trim(),
        'bio':bio.text.trim(),
        'customStatus':custom.text.trim(),
        'presence':presence,
        'lastSeen':FieldValue.serverTimestamp()
}
);
      if(mounted){
        notice(context, 'Perfil salvo!');
        Navigator.pop(context);
}
}catch(e){
      if(mounted)notice(context, e);
}finally{
      if(mounted)setState(()=>busy=false);
}
}
    @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Editar perfil')),
      body:MeowStreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(stream:db.collection('users').doc(widget.uid).meowSnapshots(),
      builder:(c, s){
        if(!s.hasData)return const Center(child:CircularProgressIndicator());
        final d=s.data?.data()??{
}
;
        if(!loaded){
          loaded=true;
          name.text=d['displayName']?.toString()??'';
          pronouns.text=d['pronouns']?.toString()??'';
          bio.text=d['bio']?.toString()??'';
          custom.text=d['customStatus']?.toString()??'';
          presence=presenceLabels.containsKey(d['presence'])?d['presence'].toString():'online';
}
          return ListView(children:[Stack(clipBehavior:Clip.none, children:[const SizedBox(height:235,width:double.infinity),ProfileBanner(uid:widget.uid,data:d), Positioned(right:10,top:10,child:Row(mainAxisSize:MainAxisSize.min,children:[ChangeImage('profile',widget.uid,'banner','Trocar banner',iconOnly:true),IconButton.filledTonal(tooltip:'Remover banner',onPressed:()async{await db.collection('users').doc(widget.uid).update({'bannerHidden':true});},icon:const Icon(Icons.hide_image))])), Positioned(left:18, bottom:10, child:Stack(alignment:Alignment.bottomRight, children:[PrivateImage(scope:'profile',
        id:widget.uid, slot:'avatar', size:90
), ChangeImage('profile', widget.uid, 'avatar', 'Trocar foto', iconOnly:true)]))]), const SizedBox(height:8),
            Padding(padding:const EdgeInsets.all(18), child:Column(children:[TextField(controller:name, maxLength:15,
          decoration:const InputDecoration(labelText:'Nome de exibição')
), const SizedBox(height:10), TextField(controller:pronouns, maxLength:40, decoration:const InputDecoration(labelText:'Pronomes')),
            const SizedBox(height:10), TextField(controller:bio, maxLength:300, maxLines:4, decoration:const InputDecoration(labelText:'Biografia')),
            const SizedBox(height:10), TextField(controller:custom, maxLength:100, decoration:const InputDecoration(labelText:'Status personalizado')),
              DropdownButtonFormField<String>(value:presence, decoration:const InputDecoration(labelText:'Disponibilidade'),
              items:presenceLabels.entries.map((e)=>DropdownMenuItem(value:e.key, child:Text(e.value))).toList(),
              onChanged:(v){
                if(v!=null)setState(()=>presence=v);
}
), const SizedBox(height:12), ProfileThemeEditor(uid:widget.uid),ChangeImage('profile',widget.uid,'background','Trocar fundo da bio'),if(d['backgroundEnabled']==true) TextButton(onPressed:()async{try{await db.collection('users').doc(widget.uid).update({'backgroundEnabled':false});}catch(e){if(c.mounted)notice(c,e);}},child:const Text('Remover fundo')),const SizedBox(height:20), SizedBox(width:double.infinity, child:FilledButton(onPressed:busy?null:save,
            child:Text(busy?'Salvando...':'Salvar alterações')
)),
]))
]);
}
)
);
}

// Keep keyboard MediaQuery dependencies inside the server-list pane, not the chat.
class MeowCompactServerHeader extends StatelessWidget {
 final String id;
 const MeowCompactServerHeader({super.key,required this.id});
 @override Widget build(BuildContext c)=>ConstrainedBox(
   constraints:BoxConstraints(maxHeight:max(0.0,min(228.0,MediaQuery.sizeOf(c).height-MediaQuery.viewInsetsOf(c).bottom-180))),
   child:SingleChildScrollView(child:ServerHeader(id:id)));
}
class ServerHeader extends StatelessWidget {
  final String id;
  const ServerHeader({
    super.key,
    required this.id
}
);
  @override Widget build(BuildContext c)=>MeowStreamBuilder<DocumentSnapshot<Map<String,
  dynamic>>>(stream:db.collection('servers').doc(id).meowSnapshots(), builder:(c, s){
    final d=s.data?.data()??{
}
;
      return Column(children:[Stack(children:[PrivateImage(scope:'server', id:id, slot:'banner', size:160, borderRadius:BorderRadius.zero), Positioned(right:8,top:8,child:IconButton.filledTonal(icon:const Icon(Icons.more_vert),onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ServerSettingsPage(id:id)))))]),
        ListTile(leading:PrivateImage(scope:'server', id:id, slot:'avatar', size:42), title:Text(d['name']?.toString()??'Servidor'),
          subtitle:Text('${(d['members'] as List?)?.length??0} membros'), trailing:IconButton(icon:const Icon(Icons.more_vert),
        onPressed:()=>Navigator.push(c, MaterialPageRoute(builder:(_)=>ServerSettingsPage(id:id)))
)
), const Divider(height:1)
]);
}
);
}

class ServerSettingsPage extends StatelessWidget {
  final String id;
  const ServerSettingsPage({
    super.key,
    required this.id
}
);
    @override Widget build(BuildContext pageContext)=>Scaffold(appBar:AppBar(title:const Text('Configurações do servidor')),
      body:StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(stream:db.collection('servers').doc(id).meowSnapshots(),
      builder:(c, s){
        if(s.hasError)return Center(child:Text('Erro ao carregar servidor: ${s.error}'));
        if(!s.hasData)return const Center(child:CircularProgressIndicator());
        final d=s.data?.data()??{
}
;
        final owner=d['ownerId']==myUid;
        if(!s.data!.exists)return const Center(child:Text('Servidor indisponível.'));
        if(d['deleting']==true)return Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(
          mainAxisSize:MainAxisSize.min,children:[const Text('Servidor em processo de exclusão.',textAlign:TextAlign.center),
          if(owner)FilledButton(onPressed:()async{
            final done=await confirmServerDelete(pageContext,id,resume:true);
            if(done&&pageContext.mounted&&ModalRoute.of(pageContext)?.isCurrent==true)Navigator.pop(pageContext);
          },child:const Text('Retomar exclusão'))],
        )));
          return ListView(children:[PrivateImage(scope:'server', id:id, slot:'banner', size:160), const SizedBox(height:16),
            Center(child:PrivateImage(scope:'server', id:id, slot:'avatar', size:88)), Padding(padding:const EdgeInsets.all(18),
              child:Column(children:[Text(d['name']?.toString()??'Servidor', style:const TextStyle(fontSize:22)),
                const SizedBox(height:18), if(owner) OutlinedButton.icon(icon:const Icon(Icons.edit),label:const Text('Renomear servidor'),onPressed:()async{final v=await showTextPrompt(c,'Nome do servidor',d['name']?.toString()??'');if(v!=null&&v.isNotEmpty)await db.collection('servers').doc(id).update({'name':v});}), const SizedBox(height:12), if(owner) ListTile(title:const Text('Organizar categorias e canais'),trailing:const Icon(Icons.chevron_right),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ServerOrganizationPage(id:id)))), if(owner||(d['adminIds'] is List&&(d['adminIds'] as List).contains(myUid)))ListTile(title:const Text('Emojis e figurinhas'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ExpressionSettings(server:id)))),if(owner) SwitchListTile(title:const Text('Permitir @everyone a todos os membros'),value:d['everyoneEnabled']==true,onChanged:(v)async{try{await db.collection('servers').doc(id).update({'everyoneEnabled':v});}catch(e){if(c.mounted)notice(c,e);}}),if(owner) ChangeImage('server', id, 'avatar', 'Trocar ícone (8 MiB)'),if(owner) ChangeImage('server',id,'banner','Trocar banner (15 MiB)'),if(owner) OutlinedButton.icon(onPressed:()async{final done=await confirmServerDelete(pageContext,id);if(done&&pageContext.mounted&&ModalRoute.of(pageContext)?.isCurrent==true)Navigator.pop(pageContext);},icon:const Icon(Icons.delete),label:const Text('Excluir servidor')),if(!owner)OutlinedButton.icon(onPressed:()=>confirmLeaveServer(c,id),icon:const Icon(Icons.logout),label:const Text('Sair do servidor'))
])
)
]);
}
)
);
}


Future<String?> showTextPrompt(BuildContext c,String title,String initial) async {
  String value=initial;
  return showDialog<String>(context:c,builder:(dialog)=>AlertDialog(title:Text(title),
    content:TextFormField(initialValue:initial,maxLength:40,onChanged:(v)=>value=v),
    actions:[TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Cancelar')),
      FilledButton(onPressed:()=>Navigator.pop(dialog,value.trim()),child:const Text('Salvar'))]));
}
class ServerOrganizationPage extends StatelessWidget {
  final String id;
  const ServerOrganizationPage({super.key,required this.id});
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Categorias e canais')),
    body:MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('servers').doc(id).collection('channels').meowSnapshots(),
      builder:(c,s){
        if(!s.hasData)return const Center(child:CircularProgressIndicator());
        final docs=[...s.data!.docs];
        docs.sort((a,b)=>((a.data()['order'] as num?)?.toInt()??0).compareTo((b.data()['order'] as num?)?.toInt()??0));
        final cats=<String>[];
        for(final d in docs){final cat=d.data()['category']?.toString()??'GERAL';if(!cats.contains(cat))cats.add(cat);}
        return ListView(children:[for(final cat in cats)...[
          ListTile(title:Text(cat),trailing:IconButton(icon:const Icon(Icons.edit),onPressed:()async{
            final v=await showTextPrompt(c,'Renomear categoria',cat);
            if(v==null||v.isEmpty||v==cat)return;
            final batch=db.batch();
            for(final d in docs.where((d)=>(d.data()['category']??'GERAL')==cat))batch.update(d.reference,{'category':v});
            await batch.commit();
          })),
          for(final d in docs.where((d)=>(d.data()['category']??'GERAL')==cat))ListTile(
            leading:const Icon(Icons.tag),title:Text(d.data()['name']?.toString()??'canal'),
            trailing:PopupMenuButton<String>(onSelected:(action)async{
              if(action=='rename'){final v=await showTextPrompt(c,'Renomear canal',d.data()['name']?.toString()??'');if(v!=null&&v.isNotEmpty)await d.reference.update({'name':v});}
              if(action=='move'){final v=await showTextPrompt(c,'Mover para categoria',cat);if(v!=null&&v.isNotEmpty)await d.reference.update({'category':v});}
              if(action=='up'||action=='down'){
                final group=docs.where((x)=>(x.data()['category']??'GERAL')==cat).toList();
                final idx=group.indexWhere((x)=>x.id==d.id);final other=idx+(action=='up'?-1:1);
                if(other<0||other>=group.length)return;
                final batch=db.batch();
                for(var i=0;i<group.length;i++){final item=group[i==idx?other:i==other?idx:i];batch.update(item.reference,{'order':i+1});}
                await batch.commit();
              }
            },itemBuilder:(_)=>const [PopupMenuItem(value:'rename',child:Text('Renomear')),PopupMenuItem(value:'move',child:Text('Mover de categoria')),PopupMenuItem(value:'up',child:Text('Subir')),PopupMenuItem(value:'down',child:Text('Descer'))]),
          ),
        ]]);
      }));
}

class SocialHome extends StatefulWidget {
  const SocialHome({
    super.key
}
);
  @override State<SocialHome> createState()=>_SocialHomeState();
}

class _SocialHomeState extends State<SocialHome> with WidgetsBindingObserver {
  String? serverId,
  channelId;
  String channelName='geral';
  int tab=0;
  bool showingChannels=true;
  final collapsed=<String>{
}
;
  StreamSubscription<String>? tokenSub;
  StreamSubscription<RemoteMessage>? foregroundSub,openedSub;
  OverlayEntry? notificationOverlay; Timer? notificationTimer;
  final seenNotifications=<String>{};
  Timer? presenceTimer;
  bool appActive = true;
  @override void initState(){
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initNotifications();
    touchPresence();
    presenceTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (appActive) touchPresence();
    });
}
  Future<void> touchPresence()async{
    try{
      final ref=db.collection('users').doc(myUid);
      await ref.update({
        'lastSeen':FieldValue.serverTimestamp()
}
);
}catch(_){
}
}
  @override void didChangeAppLifecycleState(AppLifecycleState state){
    appActive = state == AppLifecycleState.resumed;
    if (appActive) touchPresence();
}
  Future<void> initNotifications()async{
    try{
      final fcm=FirebaseMessaging.instance;final registeredUid=myUid;
      await fcm.requestPermission(alert:true, badge:true, sound:true);
      if(!mounted)return;
      foregroundSub=FirebaseMessaging.onMessage.listen(showNotification);
      openedSub=FirebaseMessaging.onMessageOpenedApp.listen(openNotification);
      final initial=await fcm.getInitialMessage();
      if(initial!=null&&mounted)WidgetsBinding.instance.addPostFrameCallback((_){if(mounted)openNotification(initial);});
      final token=await fcm.getToken();
      if(token!=null)await db.collection('users').doc(myUid).collection('devices').doc(token).set({
        'token':token,
        'updatedAt':FieldValue.serverTimestamp()
}
);
      tokenSub=fcm.onTokenRefresh.listen((token)async{
        if(!mounted||FirebaseAuth.instance.currentUser?.uid!=registeredUid)return;
        try{
          await db.collection('users').doc(myUid).collection('devices').doc(token).set({
            'token':token,
            'updatedAt':FieldValue.serverTimestamp()
}
);
}catch(_){
}
}
);
}catch(e){
      debugPrint('FCM não configurado: $e');
}
}
  @override void dispose(){
    WidgetsBinding.instance.removeObserver(this);
    tokenSub?.cancel(); foregroundSub?.cancel(); openedSub?.cancel(); dismissNotification();
    presenceTimer?.cancel();
    super.dispose();
}
  void dismissNotification(){notificationTimer?.cancel();notificationOverlay?.remove();notificationOverlay=null;}
  Future<void> showNotification(RemoteMessage message) async {
    final path=message.data['messagePath']??'';
    if(!mounted||message.data['recipientId']!=FirebaseAuth.instance.currentUser?.uid||!validMessagePath(path)||!seenNotifications.add(path))return;
    if(seenNotifications.length>300)seenNotifications.remove(seenNotifications.first);
    if(activeThread.value==threadFromPath(path))return;
    try{
      final snap=await db.doc(path).get();if(!snap.exists||!mounted)return;
      final d=snap.data()!;final sender=d['authorId']?.toString()??'';
      final u=(await db.collection('users').doc(sender).get()).data()??{};
      final text=(d['text']?.toString()??'').trim();
      if(!mounted||activeThread.value==threadFromPath(path))return;
      dismissNotification();
      notificationOverlay=OverlayEntry(builder:(c)=>Positioned(top:MediaQuery.paddingOf(c).top+8,left:12,right:12,child:MeowNotificationBanner(key:ValueKey(path),sender:sender,title:userLabel(u),subtitle:message.data['kind']=='reply'?'Respondeu à sua mensagem':message.data['kind']=='mention'?'Mencionou você':path.startsWith('dms/')?'Mensagem privada':'Mensagem no servidor',preview:text.isEmpty?'Nova mensagem':text,onDismiss:dismissNotification,onTap:(){dismissNotification();openNotification(message);} )));
      final overlay=meowNavigator.currentState?.overlay;if(overlay==null){notificationOverlay=null;return;}
      overlay.insert(notificationOverlay!);notificationTimer=Timer(const Duration(seconds:5),dismissNotification);
    }catch(_){}
  }
  Future<void> openNotification(RemoteMessage message) async {
    if(!mounted||message.data['recipientId']!=FirebaseAuth.instance.currentUser?.uid)return;
    final path=message.data['messagePath']??'';if(!validMessagePath(path))return;
    try{
      final snap=await db.doc(path).get();if(!snap.exists||!mounted)return;
      final parts=path.split('/');final nav=meowNavigator.currentState;if(nav==null)return;
      if(parts.first=='dms'){
        final dm=(await db.collection('dms').doc(parts[1]).get()).data();final others=List<String>.from(dm?['members']??[]).where((x)=>x!=myUid);
        if(others.isNotEmpty&&mounted)nav.push(CupertinoPageRoute<void>(builder:(_)=>DmChatPage(id:parts[1],other:others.first,uid:myUid,initialMessageId:parts.last)));
      }else{
        final ch=(await db.collection('servers').doc(parts[1]).collection('channels').doc(parts[3]).get()).data();
        if(mounted)nav.push(MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:MeowChannelTitle(server:parts[1],name:ch?['name']?.toString()??'canal'),actions:[MuteButton(thread:'server:${parts[1]}:${parts[3]}')]),body:MessageThread(collection:db.collection('servers').doc(parts[1]).collection('channels').doc(parts[3]).collection('messages'),uid:myUid,serverId:parts[1],threadId:'server:${parts[1]}:${parts[3]}',initialMessageId:parts.last))));
      }
    }catch(e){if(mounted)notice(context,'Mensagem indisponível.');}
  }
  Future<String?> prompt(String title, String hint, {int maxLength = 40}) async {
    String value = '';
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          autofocus: true,
          maxLength: maxLength,
          decoration: InputDecoration(hintText: hint),
          onChanged: (text) => value = text,
          onSubmitted: (_) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(value.trim()), child: const Text('Confirmar')),
        ],
      ),
    );
  }
  Future<void> createServer() async {
    final n = await prompt('Criar servidor', 'Nome');
    if (!mounted || n == null || n.isEmpty) return;
    try {
      final server = db.collection('servers').doc();
      final channel = server.collection('channels').doc();
      final batch = db.batch();
      batch.set(server, {
        'name': n,
        'ownerId': myUid,
        'members': [myUid],
        'createdAt': FieldValue.serverTimestamp(),
      });
      batch.set(channel, {
        'name': 'geral',
        'category': 'GERAL',
        'createdAt': FieldValue.serverTimestamp(),
      });
      await batch.commit();
      if (!mounted) return;
      setState(() {
        serverId = server.id;
        channelId = null;
        showingChannels = true;
      });
    } catch (e) {
      if (mounted) notice(context, 'Não foi possível criar o servidor: $e');
    }
  }

  Future<void> createChannel() async {
    final id = serverId;
    if (id == null) return;
    final n = await prompt('Criar canal', 'Nome');
    if (!mounted || n == null || n.isEmpty) return;
    final category = await prompt('Categoria', 'GERAL');
    if (!mounted || category == null) return;
    try {
      await db.collection('servers').doc(id).collection('channels').add({
        'name': n,
        'category': category.isEmpty ? 'GERAL' : category,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) notice(context, 'Canal criado!');
    } catch (e) {
      if (mounted) notice(context, 'Não foi possível criar o canal: $e');
    }
  }
  Future<void> createInvite()async{
    if(serverId==null)return;
    const alphabet='ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r=Random.secure();
    final code=List.generate(10, (_)=>alphabet[r.nextInt(alphabet.length)]).join();
    try{
      await db.collection('invites').doc(code).set({
        'serverId':serverId,
        'createdBy':myUid,
        'createdAt':FieldValue.serverTimestamp(),
        'active':true
}
);
      if(!mounted)return;
        await showDialog<void>(context:context, builder:(c)=>AlertDialog(title:const Text('Convite'), content:SelectableText(code,
      style:const TextStyle(fontSize:24)
), actions:[TextButton(onPressed:(){
        Clipboard.setData(ClipboardData(text:code));
        Navigator.pop(c);
}
, child:const Text('Copiar')), TextButton(onPressed:()=>Navigator.pop(c), child:const Text('Fechar'))]));
}catch(e){
      if(mounted)notice(context, e);
}
}
  Future<void> joinInvite()async{
    final code=(await prompt('Entrar com convite', 'Código', maxLength:20))?.toUpperCase();
    if(!mounted||code==null||code.isEmpty)return;
    try{
      final d=(await db.collection('invites').doc(code).get()).data();
      if(d==null||d['active']!=true)throw Exception('Convite inválido');
      final id=d['serverId'].toString();
      final batch=db.batch();
      batch.set(db.collection('joinProofs').doc(id).collection('users').doc(myUid), {
        'serverId':id,
        'code':code
}
);
      batch.update(db.collection('servers').doc(id), {
        'members':FieldValue.arrayUnion([myUid])
}
);
      await batch.commit();
      if(mounted)setState((){
        serverId=id;
        channelId=null;
        showingChannels=true;
}
);
}catch(e){
      if(mounted)notice(context, e);
}
}
    Widget rail()=>SizedBox(width:76, child:ColoredBox(color:const Color(0xFF0B0C11), child:Column(children:[IconButton(onPressed:createServer,
  icon:const Icon(Icons.add_circle, color:purple)
), IconButton(onPressed:joinInvite, icon:const Icon(Icons.group_add)), Expanded(child:MeowStreamBuilder<QuerySnapshot<Map<String,
      dynamic>>>(stream:db.collection('servers').where('members', arrayContains:myUid).meowSnapshots(), builder:(c,
    s
)=>ListView(children:[UnreadDmRail(uid:myUid),for(final d in s.data?.docs??[])Padding(key:ValueKey(d.id),padding:const EdgeInsets.symmetric(vertical:5),
      child:IconButton(tooltip:d.data()['name']?.toString()??'Servidor', onPressed:()=>setState((){
        serverId=d.id;
        channelId=null;
        showingChannels=true;
}
), icon:Stack(clipBehavior:Clip.none,children:[PrivateImage(scope:'server', id:d.id, slot:'avatar', size:48),if(d.data()['deleting']==true)const Positioned(right:-2,bottom:-2,child:Icon(Icons.hourglass_top,size:16,color:Colors.amber))else Positioned(right:-2,bottom:-2,child:ServerUnreadDot(key:ValueKey(d.id),serverId:d.id,uid:myUid))]))
)]))
)])));
  Widget channelList(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs){
    final groups=<String,
    List<QueryDocumentSnapshot<Map<String,
    dynamic>>>>{
}
;
    final ordered=[...docs]..sort((a,b)=>((a.data()['order'] as num?)?.toInt()??0).compareTo((b.data()['order'] as num?)?.toInt()??0));
    for(final d in ordered){
      final cat=d.data()['category']?.toString()??'GERAL';
      groups.putIfAbsent(cat, ()=>[]).add(d);
}
      return ListView(children:[for(final g in groups.entries)...[ListTile(dense:true, title:Text(g.key,
    style:const TextStyle(fontSize:12, color:Colors.white70)
), leading:Icon(collapsed.contains(g.key)?Icons.chevron_right:Icons.expand_more), onLongPress:()async{final server=await db.collection('servers').doc(serverId).get();if(server.data()?['ownerId']!=myUid)return;final v=await showTextPrompt(context,'Renomear categoria',g.key);if(v==null||v.isEmpty)return;final batch=db.batch();for(final d in g.value)batch.update(d.reference,{'category':v});await batch.commit();}, onTap:()=>setState((){
      if(!collapsed.add(g.key))collapsed.remove(g.key);
}
),), if(!collapsed.contains(g.key))for(final d in g.value)ListTile(leading:const Icon(Icons.tag),
      title:Text(d.data()['name']?.toString()??'canal'),trailing:ThreadUnreadDot(threadId:'server:$serverId:${d.id}',uid:myUid,collection:d.reference.collection('messages')), onLongPress:()async{final server=await db.collection('servers').doc(serverId).get();if(server.data()?['ownerId']!=myUid)return;final v=await showTextPrompt(context,'Renomear canal',d.data()['name']?.toString()??'');if(v!=null&&v.isNotEmpty)await d.reference.update({'name':v});}, onTap:()=>setState((){
        channelId=d.id;
        channelName=d.data()['name']?.toString()??'canal';
        showingChannels=false;
}
)
)]]);
}
  // Keep navigation usable if a server becomes unavailable while its chat is open.
  void restoreServerNavigation(String selected){
    if(showingChannels)return;
    WidgetsBinding.instance.addPostFrameCallback((_){
      if(mounted&&serverId==selected&&!showingChannels)setState(()=>showingChannels=true);
    });
  }
  Widget serverContent(){
    final selected=serverId;
    if(selected==null)return Row(children:[rail(), const Expanded(child:Center(child:Text('Crie um servidor ou entre com um convite.')))]);
    return MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(
      key:ValueKey('membership:$selected'),
      stream:db.collection('servers').where('members',arrayContains:myUid).meowSnapshots(),
      builder:(c,s){
        if(s.hasError){restoreServerNavigation(selected);return Row(children:[rail(),const Expanded(child:Center(child:Text('Não foi possível carregar os servidores.')))]);}
        if(!s.hasData)return Row(children:[rail(),const Expanded(child:Center(child:CircularProgressIndicator()))]);
        final matches=s.data!.docs.where((d)=>d.id==selected);
        if(matches.isEmpty){
          restoreServerNavigation(selected);
          return Row(children:[rail(),const Expanded(child:Center(child:Padding(padding:EdgeInsets.all(16),child:Text('Servidor indisponível. Selecione outro servidor.',textAlign:TextAlign.center))))]);
        }
        final data=matches.first.data();
        if(data['deleting']==true){
          restoreServerNavigation(selected);
          return Row(children:[rail(),Expanded(child:Center(child:Padding(padding:const EdgeInsets.all(16),child:Column(
            mainAxisSize:MainAxisSize.min,children:[const Text('Servidor em processo de exclusão.',textAlign:TextAlign.center),
            if(data['ownerId']==myUid)FilledButton(onPressed:()async{
              await confirmServerDelete(c,selected,resume:true);
            },child:const Text('Retomar exclusão'))],
          ))))]);
        }
        return activeServerContent(selected);
      },
    );
  }
  Widget activeServerContent(String selected){
    return MeowStreamBuilder<QuerySnapshot<Map<String,
      dynamic>>>(key:ValueKey(selected), stream:db.collection('servers').doc(selected).collection('channels').meowSnapshots(),
      builder:(c, s){
        if(s.hasError){restoreServerNavigation(selected);return Row(children:[rail(),const Expanded(child:Center(child:Text('Canais indisponíveis. Selecione outro servidor.')))]);}
        final docs=s.data?.docs??[];
        final active=docs.any((d)=>d.id==channelId)?channelId:(docs.isEmpty?null:docs.first.id);
        final activeDoc=docs.where((d)=>d.id==active);
        final activeName=activeDoc.isEmpty?'canal':activeDoc.first.data()['name']?.toString()??'canal';
        return ChannelSlide(open:showingChannels,onChange:(v){if(v)FocusManager.instance.primaryFocus?.unfocus();setState(()=>showingChannels=v);},
          list:Row(children:[rail(),Expanded(child:ColoredBox(color:panel,child:Column(children:[MeowCompactServerHeader(id:serverId!),Row(children:[const Expanded(child:Padding(padding:EdgeInsets.all(12),child:Text('Canais',style:TextStyle(fontSize:18)))),IconButton(onPressed:createChannel,icon:const Icon(Icons.add)),IconButton(onPressed:createInvite,icon:const Icon(Icons.share))]),Expanded(child:channelList(docs))])))]),
          chat:Column(children:[ListTile(leading:IconButton(icon:const Icon(Icons.arrow_back),onPressed:(){FocusManager.instance.primaryFocus?.unfocus();setState(()=>showingChannels=true);}),title:InkWell(onTap:()=>showGeneralDialog(context:context,barrierDismissible:true,barrierLabel:'Membros',transitionDuration:const Duration(milliseconds:220),pageBuilder:(c,_,__)=>Align(alignment:Alignment.centerRight,child:Material(color:panel,child:SizedBox(width:min(MediaQuery.sizeOf(c).width*.85,350.0),child:ServerMembers(server:serverId!)))),transitionBuilder:(c,a,_,child)=>SlideTransition(position:Tween(begin:const Offset(1,0),end:Offset.zero).animate(a),child:child)),child:MeowChannelTitle(server:selected,name:activeName)),trailing:active==null?null:MuteButton(thread:'server:$serverId:$active')),Expanded(child:active==null?const Center(child:Text('Sem canais')):MessageThread(key:ValueKey('$serverId/$active'),collection:db.collection('servers').doc(serverId).collection('channels').doc(active).collection('messages'),uid:myUid,serverId:serverId,threadId:'server:$serverId:$active',visible:!showingChannels&&tab==2))]));
      });
  }
  @override Widget build(BuildContext c){
    final inChannel=tab==2&&!showingChannels;
    return PopScope(canPop:!inChannel,onPopInvokedWithResult:(didPop,result){
      if(!didPop&&inChannel&&mounted)setState(()=>showingChannels=true);
    },child:Scaffold(
      drawer:MeowAccountDrawer(uid:myUid),
      drawerEnableOpenDragGesture:!inChannel,
      appBar:inChannel?null:AppBar(automaticallyImplyLeading:false,
        title:Builder(builder:(c)=>MeowAccountHeader(uid:myUid,onTap:()=>Scaffold.of(c).openDrawer())),
        actions:[IconButton(tooltip:'Solicitações de mensagens',icon:Stack(clipBehavior:Clip.none,children:[const Icon(Icons.mail_outline),Positioned(right:-3,top:-3,child:DmRequestsDot(uid:myUid))]),onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>DmRequestsPage(uid:myUid)))),IconButton(tooltip:'Configurações',icon:const Icon(Icons.more_vert),onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const AppSettingsPage())))]),
      body:SafeArea(top:inChannel,bottom:false,child:MeowTabs(index:tab,children:[
        const Center(child:Text('Em desenvolvimento',style:TextStyle(fontSize:20,fontWeight:FontWeight.w600))),
        MeowDiscover(uid:myUid),serverContent(),DmListPage(uid:myUid),
      ])),
      bottomNavigationBar:inChannel?null:MeowBottomBar(index:tab,onSelected:(i){FocusManager.instance.primaryFocus?.unfocus();setState(()=>tab=i);}),
    ));
  }

}

String dmId(String a, String b){
  final ids=[a, b]..sort();
  return '${ids[0]}_${ids[1]}';
}
// A conversa so libera mensagens depois da amizade mutua ou do aceite.
Future<void> openDm(BuildContext context, String other) async {
  final me = FirebaseAuth.instance.currentUser?.uid;
  if (me == null || other == me || other.isEmpty) return;
  final id = dmId(me, other);
  try {
    final otherUser = await db.collection('users').doc(other).get();
    if (!otherUser.exists) throw Exception('Usuario nao encontrado.');
    final dm = db.collection('dms').doc(id);
    await db.runTransaction((tx) async {final existingDm=await tx.get(dm);if(!existingDm.exists)tx.set(dm,{'members':[me,other]..sort()});});
    final follows = await db.collection('users').doc(me).collection('following').doc(other).get();
    final followed = await db.collection('users').doc(other).collection('following').doc(me).get();
    if (!(follows.exists && followed.exists)) {
      final requestRef = db.collection('dmRequests').doc(id);
      final existing = await requestRef.get();
      if (!existing.exists) {
        await requestRef.set({
          'from': me,
          'to': other,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else if (existing.data()?['status'] == 'declined') {
        if (context.mounted) notice(context, 'Esta solicitacao foi recusada.');
        return;
      }
    }
    if (context.mounted) {
      Navigator.push(context, CupertinoPageRoute<void>(
        builder: (_) => DmChatPage(id: id, other: other, uid: me),
      ));
    }
  } catch (e) {
    if (context.mounted) notice(context, 'Nao foi possivel abrir a DM: $e');
  }
}

class DmListPage extends StatefulWidget {
 final String uid;
 const DmListPage({super.key,required this.uid});
 @override State<DmListPage> createState()=>_DmListPageState();
}
class _DmListPageState extends State<DmListPage> {
 String query='';
 @override Widget build(BuildContext c)=>Column(children:[
  ListTile(title:const Text('Mensagens privadas',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),trailing:Stack(children:[IconButton(tooltip:'Solicitações',onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>DmRequestsPage(uid:widget.uid))),icon:const Icon(Icons.mail_outline)),Positioned(right:5,top:5,child:DmRequestsDot(uid:widget.uid))])),
  Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:TextField(decoration:const InputDecoration(hintText:'Buscar por nome ou ID',prefixIcon:Icon(Icons.search)),onChanged:(v)=>setState(()=>query=v.trim().toLowerCase()))),
  Expanded(child:MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('dms').where('members',arrayContains:widget.uid).meowSnapshots(),builder:(c,s){
    if(s.hasError)return Center(child:Text('Erro: ${s.error}'));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    if(s.data!.docs.isEmpty)return const Center(child:Text('Abra o perfil de alguém para conversar.'));
    return ListView(children:[for(final d in s.data!.docs) Builder(builder:(c){
      final others=List<String>.from(d.data()['members']??[]).where((x)=>x!=widget.uid).toList();
      if(others.isEmpty)return const SizedBox.shrink();
      final other=others.first;
      return MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(other).meowSnapshots(),builder:(c,u){
        final data=u.data?.data()??{};
        final name=userLabel(data);
        final serial=meowSerial(data);
        if(query.isNotEmpty&&!name.toLowerCase().contains(query)&&!(serial.isNotEmpty&&serial.contains(query.replaceFirst('#',''))))return const SizedBox.shrink();
        return ListTile(leading:ProfileAvatar(uid:other),title:Text(name),subtitle:DmPreview(id:d.id,uid:widget.uid),trailing:ThreadUnreadDot(threadId:'dm:${d.id}',uid:widget.uid,collection:d.reference.collection('messages')),onTap:()=>Navigator.push(c,CupertinoPageRoute<void>(builder:(_)=>DmChatPage(id:d.id,other:other,uid:widget.uid))));
      });
    })]);
  }))]);
}
class DmChatPage extends StatelessWidget {
 final String id,other,uid;final String? initialMessageId;
 const DmChatPage({super.key,required this.id,required this.other,required this.uid,this.initialMessageId});
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:MeowAccountHeader(uid:other,showPresence:true,onTap:()=>openProfile(c,other)),actions:[MuteButton(thread:'dm:$id')]),body:DmPermissionGate(id:id,uid:uid,other:other,initialMessageId:initialMessageId));
}
// Read receipts: a user's last-read timestamp is stored separately per thread.
// Security rules must restrict each receipt to its owner.
  DocumentReference<Map<String, dynamic>> receiptRef(String thread, String uid)=>db.collection('users').doc(uid).collection('reads').doc(base64Url.encode(utf8.encode(thread)).replaceAll('=',
''
));

class UnreadLabel extends StatelessWidget {
  final String threadId,
  uid;
  const UnreadLabel({
    super.key,
    required this.threadId,
    required this.uid
}
);
  @override Widget build(BuildContext c){
    final collection=threadId.startsWith('dm:')?db.collection('dms').doc(threadId.substring(3)).collection('messages'):null;
    if(collection==null)return const SizedBox.shrink();
    return MeowStreamBuilder<DocumentSnapshot<Map<String,
    dynamic>>>(stream:receiptRef(threadId, uid).meowSnapshots(), builder:(c, r){
      final seen=r.data?.data()?['at'] as Timestamp?;
      return MeowStreamBuilder<QuerySnapshot<Map<String,
        dynamic>>>(stream:collection.orderBy('createdAt', descending:true).limit(100).meowSnapshots(), builder:(c,
      s
){
        final count=s.data?.docs.where((d){
          final t=d.data()['createdAt'];
          return d.data()['authorId']!=uid&&t is Timestamp&&(seen==null||t.compareTo(seen)>0);
}
).length??0;
        return Text(count>0?'$count não lida(s)':'Sem mensagens novas', style:TextStyle(color:count>0?purple:Colors.white54));
}
);
}
);
}
}

class MessageThread extends StatefulWidget {
  final CollectionReference<Map<String,
  dynamic>> collection;
  final String uid,
  threadId;
  final String? serverId,initialMessageId; final bool visible;
  const MessageThread({
    super.key,
    required this.collection,
    required this.uid,
    required this.threadId,
    this.serverId,this.initialMessageId,this.visible=true
}
);
  @override State<MessageThread> createState()=>_MessageThreadState();
}

class _MessageThreadState extends State<MessageThread> with RouteAware,WidgetsBindingObserver {
  final itemScroll=ItemScrollController();
  bool jumped=false,routeActive=true,foreground=true,anchored=false;
  final typingActive=ValueNotifier<bool>(false);
  Map<String,Map<String,dynamic>> people={}; bool everyoneAllowed=false;
  StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? memberSub;
  final memberSubscriptions=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};
  late Stream<QuerySnapshot<Map<String,dynamic>>> messages;
  
  int memberEpoch=0;
  Set<String> memberIds=<String>{};
  bool memberRebuildQueued=false;
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);messages=widget.collection.orderBy('createdAt',descending:true).limit(100).meowSnapshots();if(widget.visible)startMembers();if(widget.initialMessageId!=null)loadTarget();}
  void startMembers(){
    if(memberSub!=null||!widget.visible||!foreground||!routeActive)return;
    final epoch=++memberEpoch;
    final ref=widget.serverId==null?widget.collection.parent!:db.collection('servers').doc(widget.serverId);
    memberSub=ref.meowSnapshots().listen((s){if(mounted&&epoch==memberEpoch)updateMembers(s);},onError:(Object _){ });
  }
  void suspendMembers(){
    memberEpoch++;memberSub?.cancel();memberSub=null;
    for(final sub in memberSubscriptions.values){sub.cancel();}memberSubscriptions.clear();
  }
  void changedMembers(){
    if(memberRebuildQueued)return;memberRebuildQueued=true;
    // Batch bursts of user snapshots into one UI update per frame.
    WidgetsBinding.instance.addPostFrameCallback((_){memberRebuildQueued=false;if(mounted){setState((){cachedMessagePane=null;});}});
    WidgetsBinding.instance.ensureVisualUpdate();
  }
  Future<void> loadTarget()async {try{final target=await widget.collection.doc(widget.initialMessageId).get();final t=target.data()?['createdAt'];if(t is Timestamp&&mounted){final recent=await widget.collection.orderBy('createdAt',descending:true).limit(100).get();if(!recent.docs.any((d)=>d.id==target.id)&&mounted)setState((){anchored=true;jumped=false;cachedMessagePane=null;messages=widget.collection.orderBy('createdAt',descending:true).startAt([t]).limit(100).meowSnapshots();});}}catch(_){} }
  void updateMembers(DocumentSnapshot<Map<String,dynamic>> snapshot){
    if(!mounted)return;
    final d=snapshot.data()??{};final ids=List<String>.from(d['members']??[]).toSet();
    final allowed=d['ownerId']==widget.uid||d['everyoneEnabled']==true;
    var changed=everyoneAllowed!=allowed||ids.length!=memberIds.length||!ids.containsAll(memberIds);
    everyoneAllowed=allowed;memberIds=ids;
    for(final id in people.keys.toList()){if(!ids.contains(id)){people.remove(id);changed=true;}}
    for(final id in memberSubscriptions.keys.toList()){if(!ids.contains(id))memberSubscriptions.remove(id)?.cancel();}
    final epoch=memberEpoch;
    for(final id in ids){memberSubscriptions.putIfAbsent(id,()=>db.collection('users').doc(id).meowSnapshots().listen((u){
      if(!mounted||epoch!=memberEpoch||!memberIds.contains(id))return;
      final value=u.data()??{};
      final identity=<String,dynamic>{'serialId':value['serialId'],'displayName':value['displayName']};
      final previous=people[id];
      if(previous==null||previous['serialId']!=identity['serialId']||previous['displayName']!=identity['displayName']){people[id]=identity;changedMembers();}
    },onError:(Object _){ }));}
    if(changed)changedMembers();
  }
  @override void didChangeDependencies(){super.didChangeDependencies();final route=ModalRoute.of(context);if(route!=null)meowRouteObserver.subscribe(this,route);routeActive=route?.isCurrent??true;updateActive();}
  @override void didUpdateWidget(covariant MessageThread old){super.didUpdateWidget(old);if(old.visible!=widget.visible){updateActive();lastMarkedMessage=null;cachedMessagePane=null;}}
  void updateActive(){typingActive.value=widget.visible&&routeActive&&foreground;if(typingActive.value){activeThread.value=widget.threadId;startMembers();}else{if(activeThread.value==widget.threadId)activeThread.value=null;suspendMembers();if(lastTyping!=null)unawaited(stopTyping());}}
  @override void didPush(){routeActive=true;updateActive();} @override void didPopNext(){routeActive=true;updateActive();if(mounted)setState((){lastMarkedMessage=null;cachedMessagePane=null;});} @override void didPushNext(){routeActive=false;updateActive();} @override void didPop(){routeActive=false;updateActive();}
  @override void didChangeAppLifecycleState(AppLifecycleState state){foreground=state==AppLifecycleState.resumed;updateActive();if(foreground&&mounted)setState((){lastMarkedMessage=null;cachedMessagePane=null;});}
  void replyTo(QueryDocumentSnapshot<Map<String,dynamic>> doc){final d=doc.data();setState((){replyId=doc.id;replyText=d['text']?.toString()??'';replyAuthor=d['author']?.toString()??'Usuário';replyAuthorId=d['authorId']?.toString();});}
  String? get mentionQuery=>RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(input.text)?.group(1)?.toLowerCase();
  void selectMention(String name){final match=RegExp(r'@([^\s@]*)$').firstMatch(input.text);if(match==null)return;input.text=input.text.replaceRange(match.start,match.end,'@$name ');input.selection=TextSelection.collapsed(offset:input.text.length);typingChanged(input.text);}
  bool highlighted(Map<String,dynamic> d){if(d['authorId']==widget.uid)return false;final names=mentionNames(d['text']?.toString()??'');return d['replyAuthorId']==widget.uid||meowMentioned(names,widget.uid,people[widget.uid])||(names.contains('everyone')&&d['everyoneMention']==true);}
  Widget mentionSuggestions(BuildContext c,double availableHeight){
    final q=mentionQuery;
    if(q==null||availableHeight<=0)return const SizedBox.shrink();
    final suggestions=people.entries.where((e){final serial=meowSerial(e.value);return serial.isNotEmpty&&(userLabel(e.value).toLowerCase().contains(q)||serial.startsWith(q.replaceFirst('#','')));}).take(5).toList();
    final showEveryone=widget.serverId!=null&&everyoneAllowed&&'everyone'.startsWith(q);
    if(!showEveryone&&suggestions.isEmpty)return const SizedBox.shrink();
    return ConstrainedBox(
      constraints:BoxConstraints(maxHeight:min(230.0,availableHeight)),
      child:Material(color:panel,child:ListView(
        padding:EdgeInsets.zero,
        primary:false,
        shrinkWrap:true,
        children:[
          if(showEveryone)ListTile(dense:true,title:const Text('@everyone'),onTap:()=>selectMention('everyone')),
          for(final e in suggestions)ListTile(dense:true,
            leading:PrivateImage(scope:'profile',id:e.key,slot:'avatar',size:30),
            title:Text(userLabel(e.value),maxLines:1,overflow:TextOverflow.ellipsis),
            subtitle:Text(meowPublicId(e.value),maxLines:1,overflow:TextOverflow.ellipsis),
            onTap:()=>selectMention('#${meowSerial(e.value)}')),
        ],
      )),
    );
  }

  // Suggestions occupy the remaining history area, never the composer's height.
  // This uses actual parent constraints (including keyboard and reply bar).
  Widget messageArea()=>Expanded(child:LayoutBuilder(builder:(c,b)=>Stack(
    fit:StackFit.expand,
    children:[
      Column(children:[cachedMessagePane??=buildMessagePane()]),
      Positioned(left:0,right:0,bottom:0,child:ValueListenableBuilder<TextEditingValue>(
        valueListenable:input,
        builder:(c,value,_)=>mentionSuggestions(c,b.maxHeight),
      )),
    ],
  )));

  final input=TextEditingController();
  bool sending=false;
  Timestamp? lastMarkedMessage;
  Timer? typingTimer;
  DateTime? lastTyping;
  DocumentReference<Map<String,dynamic>> get typingRef=>widget.collection.parent!.collection('typing').doc(widget.uid);
  Future<void> stopTyping() async {typingTimer?.cancel();typingTimer=null;if(lastTyping==null)return;lastTyping=null;try{await typingRef.delete();}catch(_){} }
  void typingChanged(String value){
    if(!widget.visible||!routeActive||!foreground||value.trim().isEmpty){unawaited(stopTyping());return;}
    final now=DateTime.now();
    if(lastTyping==null||now.difference(lastTyping!).inMilliseconds>=1500){
      lastTyping=now;
      unawaited(typingRef.set({'at':FieldValue.serverTimestamp()}).catchError((Object _){}));
    }
    typingTimer?.cancel();
    typingTimer=Timer(const Duration(seconds:3),()=>unawaited(stopTyping()));
  }

  String? replyId,
  replyText,
  replyAuthor,replyAuthorId;
  @override void dispose(){
    meowRouteObserver.unsubscribe(this);WidgetsBinding.instance.removeObserver(this);suspendMembers();if(activeThread.value==widget.threadId)activeThread.value=null;
    stopTyping();
    typingActive.dispose();
    input.dispose();
    super.dispose();
}
  Future<void> markRead()async{
    if(!widget.visible||!foreground||!routeActive)return;
    try{
      await receiptRef(widget.threadId, widget.uid).set({
        'at':FieldValue.serverTimestamp()
}
);
}catch(_){
}
}
  Future<void> send({
    Map<String,
    dynamic>? attachment, Map<String,dynamic>? expression
}
)async{
    final text=input.text.trim();
    if((text.isEmpty&&attachment==null&&expression==null)||sending)return;
    setState(()=>sending=true);
    try{
      final u=(await db.collection('users').doc(widget.uid).get()).data()??{
}
;
      final data=<String,
      dynamic>{
        'text':text,
        'authorId':widget.uid,
        'author':userLabel(u),
        'createdAt':FieldValue.serverTimestamp()
}
;
      if(replyId!=null){
        data.addAll({
          'replyToId':replyId,
          'replyText':replyText,
          'replyAuthor':replyAuthor,if(replyAuthorId!=null)'replyAuthorId':replyAuthorId
}
);
}
      if(attachment!=null)data['attachment']=attachment;
      if(expression!=null)data['expression']=expression;
      if(widget.serverId!=null&&everyoneAllowed&&mentionNames(text).contains('everyone'))data['everyoneMention']=true;
      final sent=await widget.collection.add(data);
      unawaited(notifyMessage(sent.path));
      if(!mounted)return;
      input.clear();
      unawaited(stopTyping());
      if(mounted)setState((){
        replyId=null;
        replyText=null;
        replyAuthor=null;replyAuthorId=null;
}
);
      await markRead();
}catch(e){
      if(mounted)notice(context, 'Falha ao enviar: $e');
}finally{
      if(mounted)setState(()=>sending=false);
}
}
  bool uploading = false; double? uploadProgress;
  Future<void> attach() async {
    if (uploading || sending) return;
    setState(() {uploading=true;uploadProgress=null;});
    try {
      final source = await showModalBottomSheet<String>(
        context: context,
        builder: (c) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo), title: const Text('Galeria'),
            onTap: () => Navigator.pop(c, 'gallery')),
          ListTile(leading:const Icon(Icons.videocam),title:const Text('Vídeo da galeria'),onTap:()=>Navigator.pop(c,'video')),
          ListTile(leading:const Icon(Icons.camera_alt),title:const Text('Câmera'),onTap:()=>Navigator.pop(c,'camera')),
          ListTile(leading: const Icon(Icons.folder), title: const Text('Arquivos (25 MiB)'),
            onTap: () => Navigator.pop(c, 'files')),
        ])),
      );
      if (!mounted || source == null) return;
      final file = source == 'gallery'
          ? await ImagePicker().pickImage(source: ImageSource.gallery, requestFullMetadata: false)
          : source=='video'?await ImagePicker().pickVideo(source:ImageSource.gallery):source=='camera'?await ImagePicker().pickImage(source:ImageSource.camera,requestFullMetadata:false):await files.openFile();
      if (file == null || !mounted) return;
      final length = await file.length();
      if (length == 0 || length > attachmentLimit) {
        throw Exception('O arquivo precisa ter entre 1 byte e 25 MiB.');
      }
      if(!mounted)return;
      final confirm=await showModalBottomSheet<bool>(context:context,builder:(c)=>SafeArea(child:Padding(padding:const EdgeInsets.all(18),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.attach_file,size:36),Text(file.name),Text(fileSizeLabel(length)),const SizedBox(height:12),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Enviar arquivo')),TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancelar'))]))));
      if(confirm!=true||!mounted)return;
      final name = file.name;
      final extension = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      const mime = <String, String>{
        'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
        'gif': 'image/gif', 'webp': 'image/webp', 'pdf': 'application/pdf',
        'txt': 'text/plain', 'mp4': 'video/mp4', 'mov': 'video/quicktime',
        'mp3': 'audio/mpeg', 'wav': 'audio/wav', 'zip': 'application/zip',
      };
      final contentType = mime[extension] ?? 'application/octet-stream';
      final uri = Uri.https(imageHost, '/functions/v1/meow-anexos',
          {'thread': widget.threadId, 'name': name});
      final request = http.StreamedRequest('PUT', uri);
      request.headers.addAll({...await authHeaders(), 'Content-Type': contentType});
      request.contentLength = length;
      final client = http.Client();
      try {
        // The producer is awaited, so errors from reading the file cannot be lost.
        final producer = () async {
          try {
            var transferred=0;
            var lastPaint=DateTime.fromMillisecondsSinceEpoch(0);
            await for (final chunk in file.openRead()) {
              request.sink.add(chunk);transferred+=chunk.length;
              final now=DateTime.now();
              if(mounted&&(transferred>=length||now.difference(lastPaint)>=const Duration(milliseconds:120))){lastPaint=now;setState(()=>uploadProgress=(transferred/length).clamp(0.0,1.0).toDouble());}
            }
            await request.sink.close();
          } catch (e, st) {
            request.sink.addError(e, st);
            rethrow;
          }
        }();
        // Observe both futures immediately so an early file-read failure cannot be lost.
        late http.Response result;
        await Future.wait<void>([
          producer,
          () async {
            final response = await client.send(request).timeout(const Duration(minutes: 3));
            result = await http.Response.fromStream(response).timeout(const Duration(minutes: 3));
          }(),
        ], eagerError: true);
        if (result.statusCode != 200 && result.statusCode != 201) {
          throw Exception('Falha no upload (HTTP ${result.statusCode}): ${result.body}');
        }
        final payload = jsonDecode(result.body);
        if (payload is! Map || payload['id'] is! String ||
            payload['name'] is! String || payload['contentType'] is! String ||
            payload['size'] is! int || payload['size'] != length) {
          throw Exception('Resposta inválida do servidor de anexos.');
        }
        if(!mounted)return;
        await send(attachment: {
          'id': payload['id'], 'name': payload['name'],
          'contentType': payload['contentType'], 'size': payload['size'],
        });
      } finally {
        client.close();
      }
    } catch (e) {
      if (mounted) notice(context, 'Anexo não enviado: $e');
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }
  Future<bool> admin()async{
    if(widget.serverId==null)return false;
    final d=(await db.collection('servers').doc(widget.serverId).get()).data();
    return d?['ownerId']==widget.uid||(d?['adminIds'] is List&&(d!['adminIds'] as List).contains(widget.uid));
}
  Future<void> options(QueryDocumentSnapshot<Map<String, dynamic>> doc)async{
    final d=doc.data(),
    own=d['authorId']==widget.uid;
    bool canDelete=own;
    if(!own&&widget.serverId!=null){
      try{
        canDelete=await admin();
}catch(_){
}
}
    if(!mounted)return;
      final action=await showModalBottomSheet<String>(context:context, builder:(c)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,
        children:[ListTile(leading:const Icon(Icons.add_reaction_outlined),title:const Text('Adicionar reação'),onTap:()=>Navigator.pop(c,'react')),ListTile(leading:const Icon(Icons.reply), title:const Text('Responder'), onTap:()=>Navigator.pop(c,
      'reply'
)), if((d['text']?.toString()??'').isNotEmpty)ListTile(leading:const Icon(Icons.copy), title:const Text('Copiar mensagem'), onTap:()=>Navigator.pop(c, 'copy')), if(own)ListTile(leading:const Icon(Icons.edit), title:const Text('Editar'), onTap:()=>Navigator.pop(c,
      'edit'
)), if(canDelete)ListTile(leading:const Icon(Icons.delete), title:const Text('Apagar'), onTap:()=>Navigator.pop(c,
      'delete'
))]
)));
    if(!mounted)return;
    if(action=='copy'){
      await Clipboard.setData(ClipboardData(text:d['text']?.toString()??''));
      if(mounted)notice(context, 'Mensagem copiada!');
      return;
    }
    if(action=='reply')replyTo(doc);
    if(action=='react')await addReaction(context,doc.reference,widget.uid);
    if (action == 'edit' && own) {
      String edited = d['text']?.toString() ?? '';
      final v = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Editar mensagem'),
          content: TextFormField(
            initialValue: edited,
            maxLength: 2000,
            maxLines: 4,
            onChanged: (value) => edited = value,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, edited.trim()), child: const Text('Salvar')),
          ],
        ),
      );
      if (v != null && v.isNotEmpty) {
        try {
          await doc.reference.update({
            'text': v,
            'editedAt': FieldValue.serverTimestamp(),
          });
        } catch (e) {
          if (mounted) notice(context, e);
        }
      }
    }
    if(action=='delete'&&canDelete){
        final ok=await showDialog<bool>(context:context, builder:(c)=>AlertDialog(title:const Text('Apagar mensagem?'),
          actions:[TextButton(onPressed:()=>Navigator.pop(c, false), child:const Text('Cancelar')), FilledButton(onPressed:()=>Navigator.pop(c,
        true
), child:const Text('Apagar'))]
));
      if(ok==true){
        try{
          await doc.reference.delete();
}catch(e){
          if(mounted)notice(context, e);
}
}
}
}
    Widget? cachedMessagePane;
    Widget buildMessagePane()=>Expanded(child:StreamBuilder<QuerySnapshot<Map<String,
      dynamic>>>(stream:widget.visible?messages:null,
      builder:(c, s){
        if(s.hasError)return Center(child:Text('Erro: ${s.error}'));
        if(!s.hasData)return const Center(child:CircularProgressIndicator());
        final docs=s.data!.docs;
        if(docs.isEmpty)return const Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Image(image:AssetImage('assets/meow_foreground.png'),width:72,height:72),SizedBox(height:12),Text('Comece a conversa!')]));
        final newest = docs.first.data()['createdAt'];
        if (widget.visible && foreground && routeActive && newest is Timestamp && newest != lastMarkedMessage && !anchored) {
          lastMarkedMessage = newest;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) markRead();
          });
        }
          final targetIndex=docs.indexWhere((d)=>d.id==widget.initialMessageId);
          if(targetIndex>=0&&!jumped){jumped=true;WidgetsBinding.instance.addPostFrameCallback((_){if(mounted&&itemScroll.isAttached)itemScroll.jumpTo(index:targetIndex);});}
          return ScrollablePositionedList.builder(key:PageStorageKey<String>(widget.threadId),itemScrollController:itemScroll,reverse:true,padding:const EdgeInsets.all(12),itemCount:docs.length,itemBuilder:(c,
        i
){
          final doc=docs[i],
          d=doc.data();
          final author=d['authorId']?.toString()??'';
          final attachment=d['attachment'];
          final older=i+1<docs.length?docs[i+1].data():null;
          final grouped=older!=null && older['authorId']==author && older['createdAt'] is Timestamp && d['createdAt'] is Timestamp && (d['createdAt'] as Timestamp).toDate().difference((older['createdAt'] as Timestamp).toDate()).inMinutes.abs()<5;
          final when=d['createdAt'] is Timestamp?formatMeowTime((d['createdAt'] as Timestamp).toDate()):'Enviando...';
          final isDm=widget.serverId==null;
          final mine=author==widget.uid;
          final name=people.containsKey(author)?userLabel(people[author]!):d['author']?.toString()??'Usuário';
          final messageContents=<Widget>[
            if(d['replyToId']!=null)Container(padding:const EdgeInsets.only(left:6),decoration:const BoxDecoration(border:Border(left:BorderSide(color:Colors.white38,width:2))),child:Text('↳ ${d['replyAuthor']??''}: ${d['replyText']??''}',maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white70,fontSize:12))),
            if((d['text']?.toString()??'').isNotEmpty)MeowMessageText(text:d['text'].toString(),people:people),
            if(attachment is Map&&attachment['id'] is String)AttachmentView(key:ValueKey(attachment['id']),attachment:attachment),
            if(d['expression'] is Map)ExpressionImage(data:Map<String,dynamic>.from(d['expression'] as Map),message:doc.reference.path,size:(d['expression'] as Map)['kind']=='emoji'&&(d['text']?.toString()??'').isNotEmpty?26.0:null),
            ReactionBar(ref:doc.reference,uid:widget.uid),
            if(d['editedAt']!=null)const Text('(editada)',style:TextStyle(fontSize:11,color:Colors.white54)),
          ];
          final Widget messageBody;
          if(isDm){
            messageBody=Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
              if(!mine)...[if(grouped)const SizedBox(width:32)else ProfileAvatar(uid:author,size:32),const SizedBox(width:8)],
              Expanded(child:Align(alignment:mine?Alignment.centerRight:Alignment.centerLeft,child:FractionallySizedBox(widthFactor:.88,alignment:mine?Alignment.centerRight:Alignment.centerLeft,child:Column(crossAxisAlignment:mine?CrossAxisAlignment.end:CrossAxisAlignment.start,children:[
                Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),decoration:BoxDecoration(color:mine?const Color(0xFF6440A9):panel,borderRadius:BorderRadius.circular(16),border:highlighted(d)?Border.all(color:Colors.amber,width:1):null),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:messageContents)),
                if(!grouped)Padding(padding:const EdgeInsets.only(top:3),child:Text(when,style:const TextStyle(fontSize:11,color:Colors.white54))),
              ])))),
            ]);
          }else{
            messageBody=Row(crossAxisAlignment:CrossAxisAlignment.start,children:[grouped?const SizedBox(width:40):ProfileAvatar(uid:author),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              if(!grouped)Row(children:[Flexible(child:InkWell(onTap:()=>openProfile(c,author),child:Text(name,style:const TextStyle(fontWeight:FontWeight.bold,color:purple)))),const SizedBox(width:8),Text(when,style:const TextStyle(fontSize:11,color:Colors.white54))]),...messageContents,
            ]))]);
          }
          return ReplySwipe(key:ValueKey(doc.id),onReply:()=>replyTo(doc),child:InkWell(onLongPress:()=>options(doc),child:Container(
            decoration:!isDm&&highlighted(d)?const BoxDecoration(color:Color(0x22FFC107),border:Border(left:BorderSide(color:Colors.amber,width:3))):null,
            padding:EdgeInsets.symmetric(vertical:grouped?2:5,horizontal:4),child:messageBody)));

}
);
}
)
);
    @override Widget build(BuildContext c)=>Column(children:[if(anchored)TextButton(onPressed:()=>setState((){anchored=false;jumped=true;cachedMessagePane=null;messages=widget.collection.orderBy('createdAt',descending:true).limit(100).meowSnapshots();}),child:const Text('Voltar às mensagens recentes')),messageArea(), if(uploading)LinearProgressIndicator(value:uploadProgress),ValueListenableBuilder<bool>(valueListenable:typingActive,builder:(c,active,_)=>active?TypingLabel(collection:widget.collection.parent!.collection('typing'),uid:widget.uid):const SizedBox.shrink()), if(replyId!=null)ListTile(dense:true, title:Text('Respondendo a $replyAuthor: $replyText', maxLines:1,
  overflow:TextOverflow.ellipsis
), trailing:IconButton(icon:const Icon(Icons.close), onPressed:()=>setState((){
    replyId=null;
    replyText=null;
    replyAuthor=null;replyAuthorId=null;
}
))), SafeArea(top:false, child:Padding(padding:const EdgeInsets.all(8), child:Row(children:[IconButton(tooltip:'Anexar arquivo',
  onPressed:(sending||uploading)?null:attach, icon:Icon(uploading?Icons.hourglass_top:Icons.add_circle_outline)
), Expanded(child:TextField(controller:input, maxLength:2000, maxLines:4, minLines:1, decoration:InputDecoration(hintText:'Mensagem',counterText:'',border:OutlineInputBorder(borderRadius:BorderRadius.circular(24))), onChanged:typingChanged,onSubmitted:(_){if(!uploading)send();})), IconButton(tooltip:'Emojis e figurinhas',icon:const Icon(Icons.emoji_emotions_outlined),onPressed:(sending||uploading)?null:()async{final v=await pickExpression(context);if(!mounted||v==null)return;if(v is String){input.text+=v;typingChanged(input.text);}else if(v is Map<String,dynamic>){await send(expression:v);}}), IconButton(onPressed:(sending||uploading)?null:()=>send(), icon:const Icon(Icons.send,
  color:purple
))])))]);
}

class AttachmentView extends StatefulWidget {
 final Map attachment;const AttachmentView({super.key,required this.attachment});
 @override State<AttachmentView> createState()=>_AttachmentViewState();
}
class _AttachmentViewState extends State<AttachmentView>{
 Future<Uint8List?>? imageFuture;bool busy=false;
 bool get isImage=>(widget.attachment['contentType']?.toString()??'').startsWith('image/');
 Future<Uint8List?> fetch()=>PrivateMediaCache.get(attachmentUrl(widget.attachment['id'].toString()));
 @override void initState(){super.initState();if(isImage)imageFuture=fetch();}
 Future<void> save()async{if(busy)return;setState(()=>busy=true);try{final bytes=await fetch();if(bytes==null)throw Exception('Arquivo indisponível.');if(!mounted)return;await saveMeowFile(context,bytes,widget.attachment['name']?.toString()??'arquivo',isImage); }catch(e){if(mounted)notice(context,e);}finally{if(mounted)setState(()=>busy=false);}}
 @override void didUpdateWidget(covariant AttachmentView old){
   super.didUpdateWidget(old);
   if(old.attachment['id']!=widget.attachment['id']||old.attachment['contentType']!=widget.attachment['contentType']){
     imageFuture=isImage?fetch():null;
   }
 }
 @override Widget build(BuildContext c){
   final name=widget.attachment['name']?.toString()??'Arquivo';
   if(isImage){
     return Container(
       margin:const EdgeInsets.only(top:5),
       constraints:const BoxConstraints(maxWidth:320),
       child:FutureBuilder<Uint8List?>(future:imageFuture,builder:(c,s){
         if(s.connectionState!=ConnectionState.done){
           return const Padding(padding:EdgeInsets.all(14),child:LinearProgressIndicator());
         }
         final bytes=s.data;
         if(bytes==null){
           return TextButton(onPressed:()=>setState(()=>imageFuture=fetch()),child:const Text('Tentar carregar imagem'));
         }
         return GestureDetector(
           onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>MeowImageViewer(bytes:bytes,name:name))),
           child:ClipRRect(borderRadius:BorderRadius.circular(12),child:ConstrainedBox(
             constraints:const BoxConstraints(maxHeight:250),
             child:meowPreview(c,bytes,width:320,height:250,fit:BoxFit.contain,
               errorBuilder:(c,e,st)=>const Text('Imagem indisponível')),
           )),
         );
       }),
     );
   }
   return Container(margin:const EdgeInsets.only(top:5),constraints:const BoxConstraints(maxWidth:320),
     decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(12),border:Border.all(color:Colors.white12)),
     child:ListTile(dense:true,leading:const Icon(Icons.insert_drive_file),
       title:Text(name,maxLines:1,overflow:TextOverflow.ellipsis),
       subtitle:Text(fileSizeLabel((widget.attachment['size'] as num?)?.toInt()??0)),
       trailing:IconButton(tooltip:'Salvar arquivo',onPressed:busy?null:save,icon:Icon(busy?Icons.hourglass_top:Icons.download)),
     ),
   );
 }
}
class FriendsPage extends StatelessWidget {
 final String uid;const FriendsPage({super.key,required this.uid});
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Amigos')),body:Column(children:[
   Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:8),child:TextField(
     decoration:const InputDecoration(labelText:'Buscar por ID ou nome exato',prefixIcon:Icon(Icons.search)),
     onSubmitted:(name)=>meowFindProfile(c,name))),
   Expanded(child:MutualFriendsList(uid:uid))]));
}
Future<void> meowFindProfile(BuildContext c,String value)async{
 try{
  final found=await meowFindUsers(value);
  if(!c.mounted)return;
  if(found.isEmpty){notice(c,'Usuário não encontrado');return;}
  if(found.length==1){await openProfile(c,found.first.id);return;}
  final selected=await showModalBottomSheet<String>(context:c,builder:(sheet)=>SafeArea(child:ListView(shrinkWrap:true,children:[
    for(final d in found)ListTile(leading:ProfileAvatar(uid:d.id),title:Text(userLabel(d.data())),subtitle:Text(meowPublicId(d.data())),onTap:()=>Navigator.pop(sheet,d.id))])));
  if(c.mounted&&selected!=null)await openProfile(c,selected);
 }catch(e){if(c.mounted)notice(c,'Não foi possível buscar usuários.');}
}
Future<List<QueryDocumentSnapshot<Map<String,dynamic>>>> meowFindUsers(String value)async{
 final q=value.trim();if(q.isEmpty)return [];
 final number=q.replaceFirst('#','');
 if(RegExp(r'^[0-9]{1,8}$').hasMatch(number)){
   final id=int.parse(number);if(id<1)return [];
   return (await db.collection('users').where('serialId',isEqualTo:id).limit(1).get()).docs;
 }
 return (await db.collection('users').where('displayName',isEqualTo:q).limit(20).get()).docs;
}
class MutualFriendsList extends StatefulWidget {
 final String uid;const MutualFriendsList({super.key,required this.uid});
 @override State<MutualFriendsList> createState()=>_MutualFriendsListState();
}
class _MutualFriendsListState extends State<MutualFriendsList>{
 StreamSubscription<QuerySnapshot<Map<String,dynamic>>>? following;final mutualSubs=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};final profileSubs=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};final profiles=<String,Map<String,dynamic>>{};Timer? timer;bool loaded=false;
 @override void initState(){super.initState();following=db.collection('users').doc(widget.uid).collection('following').meowSnapshots().listen((s){if(!mounted)return;final ids=s.docs.map((d)=>d.id).toSet();for(final id in mutualSubs.keys.toList()){if(!ids.contains(id)){mutualSubs.remove(id)?.cancel();profileSubs.remove(id)?.cancel();profiles.remove(id);}}for(final id in ids){mutualSubs.putIfAbsent(id,()=>db.collection('users').doc(id).collection('following').doc(widget.uid).meowSnapshots().listen((m){if(!mounted||!mutualSubs.containsKey(id))return;if(m.exists){profiles.putIfAbsent(id,()=>{});profileSubs.putIfAbsent(id,()=>db.collection('users').doc(id).meowSnapshots().listen((u){if(mounted&&profileSubs.containsKey(id))setState(()=>profiles[id]=u.data()??{});}));}else{profileSubs.remove(id)?.cancel();profiles.remove(id);}setState((){});}));}setState(()=>loaded=true);},onError:(Object _){if(mounted)setState(()=>loaded=true);});timer=Timer.periodic(const Duration(seconds:15),(_){if(mounted)setState((){});});}
 @override void dispose(){following?.cancel();timer?.cancel();for(final s in mutualSubs.values){s.cancel();}for(final s in profileSubs.values){s.cancel();}super.dispose();}
 @override Widget build(BuildContext c){if(!loaded)return const Center(child:CircularProgressIndicator());if(profiles.isEmpty)return const Center(child:Text('Nenhum amigo ainda.'));final entries=profiles.entries.toList()..sort((a,b){final offA=currentPresence(a.value)=='offline';final offB=currentPresence(b.value)=='offline';if(offA!=offB)return offA?1:-1;return userLabel(a.value).compareTo(userLabel(b.value));});return ListView(children:[for(final e in entries)ListTile(leading:ProfileAvatar(uid:e.key),title:Text(userLabel(e.value)),subtitle:Text(meowPublicId(e.value)),onTap:()=>openProfile(c,e.key))]);}
}

String formatMeowTime(DateTime date) {
  final d=date.toLocal();
  final now=DateTime.now();
  final hh=d.hour.toString().padLeft(2,'0');
  final mm=d.minute.toString().padLeft(2,'0');
  if(d.year==now.year && d.month==now.month && d.day==now.day) return 'Hoje, $hh:$mm';
  return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year} $hh:$mm';
}
class MeowTitle extends StatelessWidget {
  static final Future<PackageInfo> _version=PackageInfo.fromPlatform();
  const MeowTitle({super.key});
  @override Widget build(BuildContext context)=>FutureBuilder<PackageInfo>(
    future:_version,builder:(context,s)=>Row(mainAxisSize:MainAxisSize.min,children:[
      const Image(image:AssetImage('assets/meow_foreground.png'),width:30,height:30),const SizedBox(width:6),const Text('Meow',style:TextStyle(fontWeight:FontWeight.bold)),const SizedBox(width:8),
      Text(s.data?.version??'',style:const TextStyle(fontSize:12,color:Colors.white54))]));
}
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});
  @override State<ChangePasswordPage> createState()=>_ChangePasswordPageState();
}
class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final current=TextEditingController(), next=TextEditingController(), confirm=TextEditingController();
  bool busy=false;
  @override void dispose(){current.dispose();next.dispose();confirm.dispose();super.dispose();}
  Future<void> save()async{
    if(next.text.length<8 || next.text!=confirm.text){notice(context,'Confira a nova senha (mínimo 8 caracteres).');return;}
    setState(()=>busy=true);
    try{
      final user=FirebaseAuth.instance.currentUser!;
      await user.reauthenticateWithCredential(EmailAuthProvider.credential(email:user.email!,password:current.text));
      await user.updatePassword(next.text);
      if(mounted){notice(context,'Senha atualizada.');Navigator.pop(context);}
    }catch(e){if(mounted)notice(context,'Não foi possível alterar a senha: $e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Alterar senha')),
    body:ListView(padding:const EdgeInsets.all(16),children:[
      TextField(controller:current,obscureText:true,decoration:const InputDecoration(labelText:'Senha atual')),
      const SizedBox(height:12),TextField(controller:next,obscureText:true,decoration:const InputDecoration(labelText:'Nova senha')),
      const SizedBox(height:12),TextField(controller:confirm,obscureText:true,decoration:const InputDecoration(labelText:'Confirmar nova senha')),
      const SizedBox(height:20),FilledButton(onPressed:busy?null:save,child:Text(busy?'Aguarde...':'Alterar senha'))]));
}

class UnreadDot extends StatelessWidget {
 final String threadId,uid;
 const UnreadDot({super.key,required this.threadId,required this.uid});
 @override Widget build(BuildContext context){
   final collection=threadId.startsWith('dm:')?db.collection('dms').doc(threadId.substring(3)).collection('messages'):null;
   if(collection==null)return const SizedBox.shrink();
   return MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:receiptRef(threadId,uid).meowSnapshots(),builder:(context,read){
     final seen=read.data?.data()?['at'] as Timestamp?;
     return MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:collection.orderBy('createdAt',descending:true).limit(20).meowSnapshots(),builder:(context,s){
       final unread=s.data?.docs.any((d){final at=d.data()['createdAt'];return d.data()['authorId']!=uid && at is Timestamp && (seen==null||at.compareTo(seen)>0);})??false;
       return unread?const Icon(Icons.circle,color:Color(0xFF38F87A),size:11):const SizedBox.shrink();
     });
   });
 }
}


// 0.5.0: perfil e temas. As cores são persistidas em Firestore como ARGB HEX.
Color meowColor(Object? value,Color fallback){
 final raw=value?.toString().trim().replaceFirst('#','')??'';
 if(!RegExp(r'^(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(raw))return fallback;
 final n=int.parse(raw,radix:16);
 return Color(raw.length==6?(0xFF000000|n):n);
}
String meowHex(Color color)=>'#${(color.value & 0xFFFFFF).toRadixString(16).padLeft(6,'0').toUpperCase()}';
LinearGradient profileGradient(Map<String,dynamic> data){
 final a=meowColor(data['themeColorA'],panel),b=meowColor(data['themeColorB'],a);
 return LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,colors:[a,data['themeGradient']==true?b:a]);
}
class ProfileBanner extends StatelessWidget{
 final String uid;final Map<String,dynamic> data;
 const ProfileBanner({super.key,required this.uid,required this.data});
 @override Widget build(BuildContext context)=>data['bannerHidden']==true
 ?const SizedBox(height:180)
 :PrivateImage(scope:'profile',id:uid,slot:'banner',size:180,borderRadius:BorderRadius.zero);
}
class ProfileThemeEditor extends StatefulWidget{
 final String uid;const ProfileThemeEditor({super.key,required this.uid});
 @override State<ProfileThemeEditor> createState()=>_ProfileThemeEditorState();
}
class _ProfileThemeEditorState extends State<ProfileThemeEditor>{
 Color first=panel,second=purple;bool gradient=false,loaded=false,saving=false;
 @override Widget build(BuildContext context)=>MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(widget.uid).meowSnapshots(),builder:(c,s){
  final d=s.data?.data()??{};
  if(!loaded&&s.hasData){loaded=true;first=meowColor(d['themeColorA'],panel);second=meowColor(d['themeColorB'],purple);gradient=d['themeGradient']==true;}
  return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[const Text('Tema do perfil',style:TextStyle(fontWeight:FontWeight.bold)),const SizedBox(height:8),
   Container(height:70,decoration:BoxDecoration(borderRadius:BorderRadius.circular(12),gradient:LinearGradient(colors:[first,gradient?second:first]))),
   SwitchListTile(title:const Text('Usar gradiente de duas cores'),value:gradient,onChanged:(v)=>setState(()=>gradient=v)),
   OutlinedButton(onPressed:()=>pick(0),child:const Text('Selecionar cor principal')),
   if(gradient)OutlinedButton(onPressed:()=>pick(1),child:const Text('Selecionar segunda cor')),
   FilledButton(onPressed:saving?null:()async{setState(()=>saving=true);try{await db.collection('users').doc(widget.uid).update({'themeColorA':meowHex(first),'themeColorB':meowHex(second),'themeGradient':gradient});if(mounted)notice(context,'Tema salvo!');}catch(e){if(mounted)notice(context,e);}finally{if(mounted)setState(()=>saving=false);}},child:Text(saving?'Salvando...':'Salvar tema')),
  ]);
 });
}
extension MeowColorEditor on _ProfileThemeEditorState {
 Future<void> pick(int index) async {
  final original=index==0?first:second;
  final result=await showDialog<Color>(context:context,builder:(c)=>MeowColorWheelDialog(initial:original));
  if(result!=null&&mounted)setState((){if(index==0)first=result;else second=result;});
 }
}

class MeowColorWheelDialog extends StatefulWidget {
 final Color initial;
 const MeowColorWheelDialog({super.key,required this.initial});
 @override State<MeowColorWheelDialog> createState()=>_MeowColorWheelDialogState();
}
class _MeowColorWheelDialogState extends State<MeowColorWheelDialog> {
 late HSVColor hsv;
 late TextEditingController hex;
 @override void initState(){
  super.initState();
  hsv=HSVColor.fromColor(widget.initial);
  hex=TextEditingController(text:meowHex(widget.initial));
 }
 @override void dispose(){hex.dispose();super.dispose();}
 void setHsv(HSVColor value){
  setState(()=>hsv=value);
  hex.value=TextEditingValue(text:meowHex(hsv.toColor()));
 }
 @override Widget build(BuildContext context)=>AlertDialog(
  title:const Text('Escolher cor'),
  content:SizedBox(width:300,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
   SizedBox(width:250,height:250,child:LayoutBuilder(builder:(c,box)=>GestureDetector(
    behavior:HitTestBehavior.opaque,
    onPanDown:(d)=>selectPoint(d.localPosition,box.biggest),
    onPanUpdate:(d)=>selectPoint(d.localPosition,box.biggest),
    child:CustomPaint(painter:MeowWheelPainter(hsv:hsv),size:box.biggest),
   ))),
   const SizedBox(height:12),
   Row(children:[const Text('Brilho'),Expanded(child:Slider(value:hsv.value,min:0,max:1,onChanged:(v)=>setHsv(hsv.withValue(v))))]),
   Container(height:36,decoration:BoxDecoration(color:hsv.toColor(),borderRadius:BorderRadius.circular(8))),
   const SizedBox(height:12),
   TextField(controller:hex,decoration:const InputDecoration(labelText:'Cor HEX (#RRGGBB)'),
    onChanged:(v){if(RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(v))setState(()=>hsv=HSVColor.fromColor(meowColor(v,hsv.toColor())));}),
  ]))),
  actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancelar')),
   FilledButton(onPressed:()=>Navigator.pop(context,hsv.toColor()),child:const Text('Aplicar'))],
 );
 void selectPoint(Offset point,Size size){
  final center=Offset(size.width/2,size.height/2);
  final dx=point.dx-center.dx,dy=point.dy-center.dy;
  final radius=min(size.width,size.height)/2;
  final saturation=(sqrt(dx*dx+dy*dy)/radius).clamp(0.0,1.0);
  final angle=(atan2(dy,dx)*180/pi+360)%360;
  setHsv(HSVColor.fromAHSV(1,angle,saturation,hsv.value));
 }
}
class MeowWheelPainter extends CustomPainter {
 final HSVColor hsv;
 const MeowWheelPainter({required this.hsv});
 @override void paint(Canvas canvas,Size size){
  final center=Offset(size.width/2,size.height/2);
  final radius=min(size.width,size.height)/2;
  final paint=Paint()..style=PaintingStyle.fill;
  // 72 hue slices; each uses radial saturation gradient.
  for(var i=0;i<72;i++){
   final a=i*2*pi/72, b=(i+1)*2*pi/72;
   final hue=i*5.0;
   final path=Path()..moveTo(center.dx,center.dy)
    ..arcTo(Rect.fromCircle(center:center,radius:radius),a,b-a+0.003,false)..close();
   paint.shader=RadialGradient(colors:[
    HSVColor.fromAHSV(1,hue,0,1).toColor(),
    HSVColor.fromAHSV(1,hue,1,1).toColor(),
   ]).createShader(Rect.fromCircle(center:center,radius:radius));
   canvas.drawPath(path,paint);
  }
  paint.shader=null;
  final angle=hsv.hue*pi/180;
  final marker=center+Offset(cos(angle),sin(angle))*radius*hsv.saturation;
  canvas.drawCircle(marker,8,Paint()..color=Colors.black..style=PaintingStyle.stroke..strokeWidth=3);
  canvas.drawCircle(marker,7,Paint()..color=Colors.white..style=PaintingStyle.stroke..strokeWidth=2);
 }
 @override bool shouldRepaint(covariant MeowWheelPainter old)=>old.hsv!=hsv;
}

// Leituras por conversa e indicadores independentes de solicitações.
class ThreadUnreadDot extends StatelessWidget{
 final String threadId,uid;final CollectionReference<Map<String,dynamic>> collection;
 const ThreadUnreadDot({super.key,required this.threadId,required this.uid,required this.collection});
 @override Widget build(BuildContext c)=>MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(uid).meowSnapshots(),builder:(c,u)=>MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:receiptRef(threadId,uid).meowSnapshots(),builder:(c,r){
 final seen=r.data?.data()?['at'] as Timestamp?;final identity=u.data?.data();
 return MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:collection.orderBy('createdAt',descending:true).limit(100).meowSnapshots(),builder:(c,s){
 final unread=s.data?.docs.where((d){final t=d.data()['createdAt'];return d.data()['authorId']!=uid&&t is Timestamp&&(seen==null||t.compareTo(seen)>0);}).toList()??[];
 final count=unread.where((d){final m=d.data();final names=mentionNames(m['text']?.toString()??'');return m['replyAuthorId']==uid||meowMentioned(names,uid,identity)||(m['everyoneMention']==true&&names.contains('everyone'));}).length;
 return Row(mainAxisSize:MainAxisSize.min,children:[if(unread.isNotEmpty)const Icon(Icons.circle,color:Color(0xFF39F57A),size:10),if(count>0)Container(margin:const EdgeInsets.only(left:3),padding:const EdgeInsets.symmetric(horizontal:5,vertical:2),decoration:BoxDecoration(color:Colors.redAccent,borderRadius:BorderRadius.circular(12)),child:Text('$count',style:const TextStyle(fontSize:10,color:Colors.white)))]);
 });}));
}
class ServerUnreadDot extends StatefulWidget{
 final String serverId,uid;const ServerUnreadDot({super.key,required this.serverId,required this.uid});
 @override State<ServerUnreadDot> createState()=>_ServerUnreadDotState();
}
class _ServerUnreadDotState extends State<ServerUnreadDot>{
 StreamSubscription<QuerySnapshot<Map<String,dynamic>>>? channels;StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? user;
 final messageSubs=<String,StreamSubscription<QuerySnapshot<Map<String,dynamic>>>>{};final receiptSubs=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};
 final receipts=<String,Timestamp?>{};final items=<String,List<QueryDocumentSnapshot<Map<String,dynamic>>>>{};Map<String,dynamic>? identity;
 int epoch=0;bool scheduled=false;
 void refresh(){if(scheduled)return;scheduled=true;WidgetsBinding.instance.addPostFrameCallback((_){scheduled=false;if(mounted)setState((){});});WidgetsBinding.instance.ensureVisualUpdate();}
 void resume(){if(channels!=null)return;final e=++epoch;
   user=db.collection('users').doc(widget.uid).meowSnapshots().listen((u){if(!mounted||e!=epoch)return;final data=u.data();if(meowSerial(identity)!=meowSerial(data)){identity=data;refresh();}},onError:(Object _){});
   channels=db.collection('servers').doc(widget.serverId).collection('channels').meowSnapshots().listen((s){if(!mounted||e!=epoch)return;final ids=s.docs.map((d)=>d.id).toSet();
     for(final id in items.keys.toList()){if(!ids.contains(id)){items.remove(id);receipts.remove(id);}}
     for(final id in messageSubs.keys.toList()){if(!ids.contains(id)){messageSubs.remove(id)?.cancel();receiptSubs.remove(id)?.cancel();}}
     for(final ch in s.docs){
       messageSubs.putIfAbsent(ch.id,()=>ch.reference.collection('messages').orderBy('createdAt',descending:true).limit(100).meowSnapshots().listen((m){if(mounted&&e==epoch){items[ch.id]=m.docs;refresh();}},onError:(Object _){if(mounted&&e==epoch){items.remove(ch.id);refresh();}}));
       receiptSubs.putIfAbsent(ch.id,()=>receiptRef('server:${widget.serverId}:${ch.id}',widget.uid).meowSnapshots().listen((r){if(mounted&&e==epoch){receipts[ch.id]=r.data()?['at'] as Timestamp?;refresh();}},onError:(Object _){}));
     }refresh();
   },onError:(Object _){if(mounted&&e==epoch){items.clear();refresh();}});
 }
 void suspend(){epoch++;channels?.cancel();channels=null;user?.cancel();user=null;for(final s in messageSubs.values){s.cancel();}for(final s in receiptSubs.values){s.cancel();}messageSubs.clear();receiptSubs.clear();}
 @override void didChangeDependencies(){super.didChangeDependencies();if(TickerMode.of(context))resume();else suspend();}
 @override void didUpdateWidget(covariant ServerUnreadDot old){super.didUpdateWidget(old);if(old.serverId!=widget.serverId||old.uid!=widget.uid){suspend();items.clear();receipts.clear();identity=null;if(TickerMode.of(context))resume();}}
 @override void dispose(){suspend();super.dispose();}
 @override Widget build(BuildContext c){var unread=false,count=0;for(final e in items.entries){final seen=receipts[e.key];for(final d in e.value){final m=d.data();final t=m['createdAt'];if(m['authorId']==widget.uid||t is! Timestamp||(seen!=null&&t.compareTo(seen)<=0))continue;unread=true;final names=mentionNames(m['text']?.toString()??'');if(m['replyAuthorId']==widget.uid||meowMentioned(names,widget.uid,identity)||(m['everyoneMention']==true&&names.contains('everyone')))count++;}}return Row(mainAxisSize:MainAxisSize.min,children:[if(unread)const Icon(Icons.circle,color:Color(0xFF39F57A),size:10),if(count>0)Container(padding:const EdgeInsets.symmetric(horizontal:4,vertical:2),decoration:BoxDecoration(color:Colors.redAccent,borderRadius:BorderRadius.circular(12)),child:Text(count>99?'99+':'$count',style:const TextStyle(fontSize:10,color:Colors.white)))]);}
}
class DmPreview extends StatelessWidget{
 final String id,uid;const DmPreview({super.key,required this.id,required this.uid});
 @override Widget build(BuildContext c)=>MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('dms').doc(id).collection('messages').orderBy('createdAt',descending:true).limit(1).meowSnapshots(),builder:(c,s){
  if(s.hasError)return const Text('Conversa',maxLines:1);
  if(s.data == null || s.data!.docs.isEmpty)return const Text('Inicie a conversa',maxLines:1);
  final d=s.data!.docs.first.data();final t=((d['text']?.toString()??'').isNotEmpty?d['text']:d['attachment'] is Map?'📎 Anexo':'Mensagem').toString();
  return Text('${d['authorId']==uid?'Você: ':''}$t',maxLines:1,overflow:TextOverflow.ellipsis);
 });
}
// Consultas restritas ao destinatario: nao varrem solicitacoes de terceiros.
Stream<QuerySnapshot<Map<String, dynamic>>> myDmRequests(String uid) =>
    db.collection('dmRequests').where('to', isEqualTo: uid).where('status', isEqualTo: 'pending').meowSnapshots();

class DmRequestsDot extends StatelessWidget {
  final String uid;
  const DmRequestsDot({super.key, required this.uid});
  @override
  Widget build(BuildContext context) => MeowStreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
    stream: myDmRequests(uid),
    builder: (context, snapshot) {
      if (snapshot.hasError) return const SizedBox.shrink();
      final pending = snapshot.data?.docs.any((doc) => doc.data()['status'] == 'pending') ?? false;
      return pending ? const Icon(Icons.circle, color: Colors.redAccent, size: 10)
          : const SizedBox.shrink();
    },
  );
}

class DmRequestsPage extends StatelessWidget {
  final String uid;
  const DmRequestsPage({super.key, required this.uid});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Solicitacoes de mensagens')),
    body: MeowStreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: myDmRequests(uid),
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('Erro: ${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final requests = snapshot.data!.docs
            .where((doc) => doc.data()['status'] == 'pending').toList();
        if (requests.isEmpty) return const Center(child: Text('Nenhuma solicitacao pendente.'));
        return ListView(children: [
          for (final request in requests)
            ListTile(
              leading: ProfileAvatar(uid: request.data()['from']?.toString() ?? ''),
              title: UserDisplayName(uid: request.data()['from']?.toString() ?? ''),
              subtitle: const Text('Quer conversar com voce'),
              trailing: Wrap(children: [
                IconButton(
                  tooltip: 'Aceitar', icon: const Icon(Icons.check),
                  onPressed: () async {
                    try {
                      await request.reference.update({'status': 'accepted'});
                      if (context.mounted) {
                        Navigator.push(context, CupertinoPageRoute<void>(builder: (_) =>
                            DmChatPage(id: request.id, other: request.data()['from'].toString(), uid: uid)));
                      }
                    } catch (e) { if (context.mounted) notice(context, e); }
                  },
                ),
                IconButton(
                  tooltip: 'Recusar', icon: const Icon(Icons.close),
                  onPressed: () async {
                    try { await request.reference.update({'status': 'declined'}); }
                    catch (e) { if (context.mounted) notice(context, e); }
                  },
                ),
              ]),
            ),
        ]);
      },
    ),
  );
}

class DmPermissionGate extends StatelessWidget {
  final String id, uid, other; final String? initialMessageId;
  const DmPermissionGate({super.key, required this.id, required this.uid, required this.other,this.initialMessageId});
  @override
  Widget build(BuildContext context) => MeowStreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
    stream: db.collection('users').doc(uid).collection('following').doc(other).meowSnapshots(),
    builder: (context, mine) => MeowStreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('users').doc(other).collection('following').doc(uid).meowSnapshots(),
      builder: (context, theirs) {
        if (mine.hasError || theirs.hasError) return const Center(child: Text('Nao foi possivel verificar a amizade.'));
        if (!mine.hasData || !theirs.hasData) return const Center(child: CircularProgressIndicator());
        if (mine.data!.exists && theirs.data!.exists) {
          return MessageThread(collection: db.collection('dms').doc(id).collection('messages'), uid: uid, threadId: 'dm:$id',initialMessageId:initialMessageId);
        }
        return MeowStreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: db.collection('dmRequests').doc(id).meowSnapshots(),
          builder: (context, request) {
            if (request.hasError) return Center(child: Text('Erro: ${request.error}'));
            if (!request.hasData) return const Center(child: CircularProgressIndicator());
            final data = request.data!.data();
            if (data?['status'] == 'accepted') {
              return MessageThread(collection: db.collection('dms').doc(id).collection('messages'), uid: uid, threadId: 'dm:$id',initialMessageId:initialMessageId);
            }
            if (data?['status'] == 'pending' && data?['to'] == uid) {
              return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Solicitacao de mensagem'),
                const SizedBox(height: 12),
                FilledButton(onPressed: () async {
                  try { await request.data!.reference.update({'status': 'accepted'}); }
                  catch (e) { if (context.mounted) notice(context, e); }
                }, child: const Text('Aceitar conversa')),
                TextButton(onPressed: () async {
                  try { await request.data!.reference.update({'status': 'declined'}); }
                  catch (e) { if (context.mounted) notice(context, e); }
                }, child: const Text('Recusar')),
              ]));
            }
            if (data?['status'] == 'pending') {
              return const Center(child: Text('Aguardando a outra pessoa aceitar sua solicitacao.'));
            }
            return const Center(child: Text('Conversa indisponivel sem amizade mutua ou solicitacao aceita.'));
          },
        );
      },
    ),
  );
}

Future<void> confirmLeaveServer(BuildContext context,String id)async{
 final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('Sair do servidor?'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancelar')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Sair'))]));
 if(ok!=true)return;
 try{await db.collection('servers').doc(id).update({'members':FieldValue.arrayRemove([myUid])});if(context.mounted)Navigator.pop(context);}catch(e){if(context.mounted)notice(context,e);}
}
// 0.8.1: deletion is exclusively performed by the authenticated backend.
Future<Map<String,dynamic>> meowServerAction(String id,String action,String uid) async {
 final user=FirebaseAuth.instance.currentUser;
 if(user==null||user.uid!=uid)throw Exception('Sessão alterada.');
 final token=await user.getIdToken();
 if(token==null||FirebaseAuth.instance.currentUser?.uid!=uid)throw Exception('Entre novamente no Meow.');
 final response=await http.post(
   Uri.https(imageHost,'/functions/v1/meow-servidores'),
   headers:{'Authorization':'Bearer $token','Content-Type':'application/json'},
   body:jsonEncode({'action':action,'serverId':id,if(action=='delete')'confirm':id}),
 ).timeout(const Duration(seconds:90));
 if(FirebaseAuth.instance.currentUser?.uid!=uid)throw Exception('Sessão alterada.');
 dynamic decoded;
 try{decoded=jsonDecode(response.body);}catch(_){decoded=null;}
 if(response.statusCode!=200&&response.statusCode!=202){
   final detail=decoded is Map&&decoded['error'] is String?decoded['error'] as String:'Serviço de exclusão indisponível.';
   throw Exception('$detail (HTTP ${response.statusCode})');
 }
 if(decoded is! Map<String,dynamic>||decoded['ok']!=true||decoded['deleted'] is! bool){
   throw Exception('Resposta inválida do serviço de exclusão.');
 }
 if(action=='delete'&&((response.statusCode==200&&decoded['deleted']!=true)||
   (response.statusCode==202&&(decoded['deleted']!=false||decoded['retryAfterMs'] is! int)))){
   throw Exception('Não foi possível confirmar o progresso da exclusão.');
 }
 if(action=='inspect'&&response.statusCode!=200)throw Exception('Resposta de inspeção inválida.');
 return decoded;
}

Future<bool> confirmServerDelete(BuildContext context,String id,{bool resume=false}) async {
 final uid=FirebaseAuth.instance.currentUser?.uid;
 if(uid==null)return false;
 final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
   title:Text(resume?'Retomar exclusão?':'Excluir servidor?'),
   content:Text(resume?'A exclusão já foi iniciada. Continue até a confirmação do servidor.':
     'Esta ação é permanente. Os canais, mensagens, convites e arquivos deste servidor serão apagados. As expressões históricas serão preservadas pelo backend.'),
   actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancelar')),
     FilledButton(onPressed:()=>Navigator.pop(c,true),child:Text(resume?'Retomar':'Excluir'))],
 ));
 if(ok!=true||!context.mounted||FirebaseAuth.instance.currentUser?.uid!=uid)return false;
 final done=await showDialog<bool>(context:context,barrierDismissible:false,
   builder:(_)=>_MeowServerDeleteDialog(id:id,uid:uid));
 if(done==true){
   PrivateMediaCache.invalidate(mediaUrl('server',id,'avatar'));
   PrivateMediaCache.invalidate(mediaUrl('server',id,'banner'));
   if(context.mounted)notice(context,'Servidor excluído definitivamente.');
 }
 return done==true;
}

class _MeowServerDeleteDialog extends StatefulWidget {
 final String id,uid;
 const _MeowServerDeleteDialog({required this.id,required this.uid});
 @override State<_MeowServerDeleteDialog> createState()=>_MeowServerDeleteDialogState();
}
class _MeowServerDeleteDialogState extends State<_MeowServerDeleteDialog> {
 bool running=true,stopped=false;
 String status='Verificando permissões…';
 String? error;
 bool get active=>mounted&&!stopped&&FirebaseAuth.instance.currentUser?.uid==widget.uid;
 @override void initState(){super.initState();unawaited(process());}
 @override void dispose(){stopped=true;super.dispose();}
 void complete(){if(!active)return;stopped=true;Navigator.pop(context,true);}
 Future<void> process() async {
   if(!active)return;
   setState((){running=true;error=null;status='Verificando permissões…';});
   try{
     final info=await meowServerAction(widget.id,'inspect',widget.uid);
     if(!active)return;
     if(info['deleted']==true){complete();return;}
     if(info['owner']!=true)throw Exception('Somente o proprietário pode excluir o servidor.');
     if(info['enabled']!=true)throw Exception('A exclusão de servidores ainda está desativada no backend.');
     while(active){
       setState(()=>status='Processando exclusão…');
       final result=await meowServerAction(widget.id,'delete',widget.uid);
       if(!active)return;
       if(result['deleted']==true){complete();return;}
       final stage=result['stage'];
       final rawDelay=result['retryAfterMs'] as int;
       final delay=Duration(milliseconds:max(250,rawDelay));
       final clock=Stopwatch()..start();
       while(active&&clock.elapsed<delay){
         final remaining=delay-clock.elapsed;
         final seconds=(remaining.inMilliseconds/1000).ceil();
         final label=switch(stage){
           'locked'||'draining'=>'Aguardando uploads em andamento: ${seconds}s',
           'storage'=>'Removendo arquivos do servidor…',
           'documents'=>'Removendo canais e mensagens…',
           'invites'=>'Removendo convites…',
           _=>'Finalizando exclusão…',
         };
         if(status!=label)setState(()=>status=label);
         await Future<void>.delayed(Duration(milliseconds:min(1000,max(1,remaining.inMilliseconds))));
       }
     }
   }catch(e){
     if(active)setState((){running=false;error=e.toString().replaceFirst('Exception: ','');});
   }finally{
     if(mounted&&!stopped&&FirebaseAuth.instance.currentUser?.uid!=widget.uid){
       setState((){running=false;error='Sessão alterada. Feche esta tela.';});
     }
   }
 }
 @override Widget build(BuildContext c)=>PopScope(
   onPopInvokedWithResult:(didPop,_) {if(didPop)stopped=true;},
   child:AlertDialog(title:const Text('Excluir servidor'),content:Column(
     mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
       if(running)...[const LinearProgressIndicator(),const SizedBox(height:16),Text(status)],
       if(error!=null)Text(error!),
       const SizedBox(height:12),
       const Text('Se a exclusão já começou, sair desta tela não a cancela. Você poderá retomá-la depois.'),
     ]),actions:[
       TextButton(onPressed:(){stopped=true;Navigator.pop(c,false);},child:const Text('Continuar depois')),
       if(!running)FilledButton(onPressed:active?()=>unawaited(process()):null,child:const Text('Tentar novamente')),
     ]),
 );
}

class ProfileBackground extends StatefulWidget {
 final String uid; const ProfileBackground({super.key,required this.uid});
 @override State<ProfileBackground> createState()=>_ProfileBackgroundState();
}
class _ProfileBackgroundState extends State<ProfileBackground> {
 late Future<Uint8List?> future;
 Uri get url=>mediaUrl('profile',widget.uid,'background');
 void refresh(){if(mounted&&changedImage.value==url)setState(()=>future=PrivateMediaCache.get(url));}
 @override void initState(){super.initState();future=PrivateMediaCache.get(url);changedImage.addListener(refresh);}
 @override void didUpdateWidget(covariant ProfileBackground old){super.didUpdateWidget(old);if(old.uid!=widget.uid)future=PrivateMediaCache.get(url);}
 @override void dispose(){changedImage.removeListener(refresh);super.dispose();}
 @override Widget build(BuildContext c)=>FutureBuilder<Uint8List?>(future:future,builder:(c,s)=>s.data==null?const SizedBox.shrink():Stack(fit:StackFit.expand,children:[meowPreview(c,s.data!,width:0,height:0,fit:BoxFit.cover,errorBuilder:(c,e,st)=>const SizedBox.shrink()),const ColoredBox(color:Color(0x99000000))]));
}
class TypingLabel extends StatefulWidget {
 final CollectionReference<Map<String,dynamic>> collection;final String uid;
 const TypingLabel({super.key,required this.collection,required this.uid});
 @override State<TypingLabel> createState()=>_TypingLabelState();
}
class _TypingLabelState extends State<TypingLabel>{
 Timer? timer;
 late Stream<QuerySnapshot<Map<String,dynamic>>> stream;
 int frame=0,epoch=0;
 final names=<String,String>{};
 final loading=<String>{};
 final observed=<String,({Timestamp stamp,int until})>{};
 final clock=Stopwatch()..start();
 QuerySnapshot<Map<String,dynamic>>? lastSnapshot;
 static const ttl=6000;
 @override void initState(){super.initState();stream=widget.collection.meowSnapshots();}
 @override void didUpdateWidget(covariant TypingLabel old){
   super.didUpdateWidget(old);
   if(old.collection.path!=widget.collection.path||old.uid!=widget.uid){
     epoch++;timer?.cancel();timer=null;names.clear();loading.clear();observed.clear();lastSnapshot=null;
     stream=widget.collection.meowSnapshots();
   }
 }
 @override void dispose(){epoch++;timer?.cancel();clock.stop();super.dispose();}
 void animate(bool active){
   if(active){timer??=Timer.periodic(const Duration(milliseconds:400),(_){if(mounted)setState(()=>frame=(frame+1)%3);});}
   else{timer?.cancel();timer=null;}
 }
 void observe(QuerySnapshot<Map<String,dynamic>> snapshot){
   if(identical(lastSnapshot,snapshot))return;
   final initial=lastSnapshot==null;
   lastSnapshot=snapshot;
   final now=clock.elapsedMilliseconds;
   final present=<String>{};
   for(final doc in snapshot.docs){
     final t=doc.data()['at'];
     if(doc.id==widget.uid||t is! Timestamp||doc.metadata.hasPendingWrites)continue;
     present.add(doc.id);
     final previous=observed[doc.id];
     if(previous?.stamp==t)continue;
     // Existing documents may be stale; subsequent live changes get a bounded
     // local lifetime, independent of later changes to the device clock.
     final age=DateTime.now().difference(t.toDate()).inMilliseconds;
     final remaining=initial||snapshot.metadata.isFromCache
       ? (ttl-max(0,age)).clamp(0,ttl).toInt():ttl;
     observed[doc.id]=(stamp:t,until:now+remaining);
   }
   observed.removeWhere((id,_)=>!present.contains(id));
 }
 Future<void> load(String id)async{
   if(names.containsKey(id)||!loading.add(id))return;
   final current=epoch;
   try{
     final d=(await db.collection('users').doc(id).get()).data()??{};
     if(mounted&&current==epoch)setState(()=>names[id]=userLabel(d));
   }catch(_){if(mounted&&current==epoch)names[id]='Alguém';}
   finally{if(current==epoch)loading.remove(id);}
 }
 @override Widget build(BuildContext c)=>MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:stream,builder:(c,s){
   final snapshot=s.data;
   if(snapshot!=null&&!s.hasError)observe(snapshot);
   final now=clock.elapsedMilliseconds;
   final ids=TickerMode.of(c)&&!s.hasError?observed.entries.where((e)=>e.value.until>now).map((e)=>e.key).toList():<String>[];
   animate(ids.isNotEmpty);
   if(ids.isEmpty)return const SizedBox.shrink();
   if(ids.length<=3){for(final id in ids){if(!names.containsKey(id))unawaited(load(id));}}
   final n=ids.map((id)=>names[id]??'Alguém').toList();
   final text=switch(n.length){1=>'${n[0]} está digitando',2=>'${n[0]} e ${n[1]} estão digitando',3=>'${n[0]}, ${n[1]} e ${n[2]} estão digitando',_=>'Muitas pessoas estão digitando'};
   return SizedBox(height:24,child:Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Row(children:[
     Flexible(child:Text(text,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:12))),
     const SizedBox(width:3),
     for(var i=0;i<3;i++)AnimatedOpacity(opacity:frame==i?1:.35,duration:const Duration(milliseconds:200),child:const Text('•')),
   ])));
 });
}
const meowEmojis=['😀','😂','😍','😭','😎','🥰','😡','🤔','😴','😺','❤️','💜','👍','👎','🔥','🎉','✨','💀','👀','🙏','🐱','🐶','🌸','🍕','🎮','💯'];
Uri expressionUrl(Map<String,dynamic> d,{String? message,String? reaction})=>Uri.https(imageHost,'/functions/v1/meow-expressoes',{'server':d['serverId'].toString(),'id':d['id'].toString(),'kind':d['kind'].toString(),if(message!=null)'message':message,if(reaction!=null)'reaction':reaction});
class ExpressionImage extends StatefulWidget {
 final Map<String,dynamic> data;final String? message,reaction;final double? size;
 const ExpressionImage({super.key,required this.data,this.message,this.reaction,this.size});
 Uri get url=>expressionUrl(data,message:message,reaction:reaction);
 @override State<ExpressionImage> createState()=>_ExpressionImageState();
}
class _ExpressionImageState extends State<ExpressionImage> {
 late Future<Uint8List?> future;
 @override void initState(){super.initState();future=PrivateMediaCache.get(widget.url);}
 @override void didUpdateWidget(covariant ExpressionImage old){super.didUpdateWidget(old);if(old.url!=widget.url)future=PrivateMediaCache.get(widget.url);}
 @override Widget build(BuildContext c){final n=widget.size??(widget.data['kind']=='sticker'?144.0:48.0);return SizedBox(width:n,height:n,child:FutureBuilder<Uint8List?>(future:future,builder:(c,s)=>s.data==null?const Icon(Icons.image_outlined):meowPreview(c,s.data!,width:n,height:n,fit:BoxFit.contain,errorBuilder:(c,e,st)=>const Icon(Icons.broken_image))));}
}
// 0.8.1: a bounded, explicit dark sheet. Load the catalogue independently
// of hidden-tab TickerMode and keep one shared future for both custom tabs.
Future<Object?> pickExpression(BuildContext context,{bool reactionOnly=false})=>
 showModalBottomSheet<Object>(context:context,isScrollControlled:true,backgroundColor:panel,
   builder:(c)=>SafeArea(top:false,child:SizedBox(
     height:min(420.0,MediaQuery.sizeOf(c).height*.72),
     child:_MeowExpressionPicker(reactionOnly:reactionOnly,uid:myUid),
   )),
 );

class _MeowExpressionGroup {
 final String id,name;
 final List<QueryDocumentSnapshot<Map<String,dynamic>>> items;
 final bool failed;
 const _MeowExpressionGroup(this.id,this.name,this.items,{this.failed=false});
}
class _MeowExpressionPicker extends StatefulWidget {
 final bool reactionOnly;
 final String uid;
 const _MeowExpressionPicker({required this.reactionOnly,required this.uid});
 @override State<_MeowExpressionPicker> createState()=>_MeowExpressionPickerState();
}
class _MeowExpressionPickerState extends State<_MeowExpressionPicker> {
 late Future<List<_MeowExpressionGroup>> catalog;
 @override void initState(){super.initState();catalog=load();}
 Future<List<_MeowExpressionGroup>> load() async {
   if(FirebaseAuth.instance.currentUser?.uid!=widget.uid)throw Exception('Sessão alterada.');
   final servers=await db.collection('servers').where('members',arrayContains:widget.uid)
     .get(const GetOptions(source:Source.server)).timeout(const Duration(seconds:15));
   final groups=await Future.wait(servers.docs.where((d)=>d.data()['deleting']!=true).map((server)async{
     final name=server.data()['name']?.toString()??'Servidor';
     try{
       final expressions=await server.reference.collection('expressions').where('active',isEqualTo:true)
         .get(const GetOptions(source:Source.server)).timeout(const Duration(seconds:15));
       return _MeowExpressionGroup(server.id,name,expressions.docs);
     }catch(_){return _MeowExpressionGroup(server.id,name,[],failed:true);}
   }));
   if(FirebaseAuth.instance.currentUser?.uid!=widget.uid)throw Exception('Sessão alterada.');
   return groups;
 }
 void retry(){setState(()=>catalog=load());}
 Widget emptyOrError(String label,{bool error=false})=>Center(child:SingleChildScrollView(child:Padding(
   padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,children:[
     Icon(error?Icons.cloud_off:Icons.emoji_emotions_outlined,color:Colors.white54,size:32),
     const SizedBox(height:8),Text(label,textAlign:TextAlign.center,style:const TextStyle(color:Colors.white70)),
     if(error)TextButton(onPressed:retry,child:const Text('Tentar novamente')),
   ]),
 )));
 Widget custom(String kind)=>FutureBuilder<List<_MeowExpressionGroup>>(future:catalog,builder:(c,s){
   if(s.connectionState!=ConnectionState.done)return const Center(child:CircularProgressIndicator());
   if(s.hasError)return emptyOrError('Não foi possível carregar as expressões.',error:true);
   final groups=s.data??[];
   final visible=groups.where((g)=>g.failed||g.items.any((item)=>item.data()['kind']==kind)).toList();
   if(visible.isEmpty)return emptyOrError(kind=='emoji'?'Nenhum emoji personalizado disponível.':'Nenhuma figurinha disponível.');
   return ListView.builder(padding:const EdgeInsets.fromLTRB(12,8,12,16),itemCount:visible.length,itemBuilder:(c,index){
     final group=visible[index];
     return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
       ListTile(contentPadding:EdgeInsets.zero,title:Text(group.name,maxLines:1,overflow:TextOverflow.ellipsis)),
       if(group.failed)ListTile(contentPadding:EdgeInsets.zero,title:const Text('Não foi possível carregar este servidor.'),
         trailing:IconButton(tooltip:'Tentar novamente',onPressed:retry,icon:const Icon(Icons.refresh)))
       else Wrap(spacing:4,runSpacing:4,children:[
         for(final item in group.items.where((d)=>d.data()['kind']==kind))
           InkWell(key:ValueKey(item.id),borderRadius:BorderRadius.circular(8),
             onTap:(){if(FirebaseAuth.instance.currentUser?.uid==widget.uid)Navigator.pop(c,<String,dynamic>{'serverId':group.id,'id':item.id,'kind':kind});},
             child:Padding(padding:const EdgeInsets.all(6),child:ExpressionImage(
               data:{'serverId':group.id,'id':item.id,'kind':kind},size:kind=='emoji'?48.0:88.0,
             )),
           ),
       ]),
     ]);
   });
 });
 @override Widget build(BuildContext c)=>Material(color:panel,child:DefaultTabController(
   length:widget.reactionOnly?2:3,child:Column(children:[
     TabBar(tabs:[const Tab(text:'Emojis'),const Tab(text:'Personalizados'),if(!widget.reactionOnly)const Tab(text:'Figurinhas')]),
     Expanded(child:TabBarView(children:[
       GridView.count(crossAxisCount:6,padding:const EdgeInsets.all(6),children:[
         for(final e in meowEmojis)TextButton(onPressed:()=>Navigator.pop(c,e),child:Text(e,style:const TextStyle(fontSize:26))),
       ]),
       custom('emoji'),if(!widget.reactionOnly)custom('sticker'),
     ])),
   ]),
 ));
}
class ExpressionSettings extends StatelessWidget{
 final String server;const ExpressionSettings({super.key,required this.server});
 CollectionReference<Map<String,dynamic>> get catalog=>db.collection('servers').doc(server).collection('expressions');
 Future<void> add(BuildContext c,String kind)async{try{final name=await showTextPrompt(c,'Nome','');if(name==null||name.length<2||name.length>32||!c.mounted)return;final f=await files.openFile(acceptedTypeGroups:const [files.XTypeGroup(label:'Imagens',extensions:['png','jpg','jpeg','gif','webp'])]);if(f==null)return;if(await f.length()>5000000)throw Exception('Limite de 5 MB.');final uri=Uri.https(imageHost,'/functions/v1/meow-expressoes',{'server':server,'kind':kind,'name':name});final response=await http.post(uri,headers:await authHeaders(),body:await f.readAsBytes()).timeout(const Duration(seconds:120));if(response.statusCode!=201)throw Exception(response.body);final d=Map<String,dynamic>.from(jsonDecode(response.body) as Map);await catalog.doc(d['id'].toString()).set({...d,'active':true,'createdAt':FieldValue.serverTimestamp()});if(c.mounted)notice(c,'Imagem adicionada.');}catch(e){if(c.mounted)notice(c,e);}}
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Emojis e figurinhas')),body:Column(children:[Wrap(children:[TextButton(onPressed:()=>add(c,'emoji'),child:const Text('Adicionar emoji')),TextButton(onPressed:()=>add(c,'sticker'),child:const Text('Adicionar figurinha'))]),Expanded(child:MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:catalog.where('active',isEqualTo:true).meowSnapshots(),builder:(c,s)=>ListView(children:[for(final d in s.data?.docs??[])ListTile(leading:ExpressionImage(data:d.data(),size:48),title:Text(d.data()['name'].toString()),trailing:PopupMenuButton<String>(onSelected:(v)async{try{if(v=='delete'){await d.reference.update({'active':false});}else{final name=await showTextPrompt(c,'Renomear',d.data()['name'].toString());if(name!=null&&name.length>=2&&name.length<=32)await d.reference.update({'name':name});}}catch(e){if(c.mounted)notice(c,e);}},itemBuilder:(_)=>const [PopupMenuItem(value:'rename',child:Text('Renomear')),PopupMenuItem(value:'delete',child:Text('Remover'))]))])))]));
}
String reactionKey(Map<String,dynamic> d){final e=d['expression'];return e is Map?'custom:${e['serverId']}:${e['id']}':'emoji:${d['emoji']}';}
Future<void> addReaction(BuildContext c,DocumentReference<Map<String,dynamic>> ref,String uid)async{final selected=await pickExpression(c,reactionOnly:true);if(selected==null||!c.mounted)return;try{final data=<String,dynamic>{'at':FieldValue.serverTimestamp(),if(selected is String)'emoji':selected,if(selected is Map<String,dynamic>)'expression':selected};final own=ref.collection('reactions').doc(uid);final old=(await own.get()).data();if(old!=null&&reactionKey(old)==reactionKey(data)){await own.delete();}else{await own.set(data);}}catch(e){if(c.mounted)notice(c,e);}}
class ReactionBar extends StatelessWidget{
 final DocumentReference<Map<String,dynamic>> ref;final String uid;const ReactionBar({super.key,required this.ref,required this.uid});
 @override Widget build(BuildContext c)=>MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:ref.collection('reactions').meowSnapshots(),builder:(c,s){final groups=<String,List<QueryDocumentSnapshot<Map<String,dynamic>>>>{};for(final d in s.data?.docs??[]){groups.putIfAbsent(reactionKey(d.data()),()=>[]).add(d);}if(groups.isEmpty)return const SizedBox.shrink();return Padding(padding:const EdgeInsets.only(top:4),child:Wrap(spacing:5,runSpacing:4,children:[for(final g in groups.values)Builder(builder:(c){final data=g.first.data();final mine=g.any((d)=>d.id==uid);return InkWell(borderRadius:BorderRadius.circular(7),onTap:()async{try{final own=ref.collection('reactions').doc(uid);if(mine){await own.delete();}else{await own.set({'at':FieldValue.serverTimestamp(),if(data['expression'] is Map)'expression':data['expression'] else 'emoji':data['emoji']});}}catch(e){if(c.mounted)notice(c,e);}},child:Container(padding:const EdgeInsets.symmetric(horizontal:7,vertical:3),decoration:BoxDecoration(color:mine?purple.withOpacity(.22):panel,borderRadius:BorderRadius.circular(7),border:Border.all(color:mine?purple:Colors.white12)),child:Row(mainAxisSize:MainAxisSize.min,children:[if(data['expression'] is Map)ExpressionImage(data:Map<String,dynamic>.from(data['expression']),message:ref.path,reaction:g.first.id,size:20)else Text(data['emoji']?.toString()??'',style:const TextStyle(fontSize:20)),const SizedBox(width:4),Text('${g.length}',style:const TextStyle(fontSize:12))])));})]));});
}

bool validMessagePath(String p)=>RegExp(r'^(dms/[\w-]+|servers/[\w-]+/channels/[\w-]+)/messages/[\w-]+$').hasMatch(p);
String threadFromPath(String p){final x=p.split('/');return x.first=='dms'?'dm:${x[1]}':'server:${x[1]}:${x[3]}';}
final _meowMentionPattern=RegExp(r'(?<![a-zA-Z0-9_])@(#(?:[0-9]{8})(?![a-zA-Z0-9_])|[a-zA-Z0-9_]+)');
Set<String> mentionNames(String text)=>_meowMentionPattern.allMatches(text).map((m)=>m.group(1)!.toLowerCase()).toSet();
String fileSizeLabel(int n)=>n>=1048576?'${(n/1048576).toStringAsFixed(1)} MiB':n>=1024?'${(n/1024).toStringAsFixed(1)} KiB':'$n B';
class MeowNotificationBanner extends StatelessWidget {
 final String sender,title,subtitle,preview;final VoidCallback onDismiss,onTap;
 const MeowNotificationBanner({super.key,required this.sender,required this.title,required this.subtitle,required this.preview,required this.onDismiss,required this.onTap});
 @override Widget build(BuildContext c)=>TweenAnimationBuilder<double>(tween:Tween(begin:0,end:1),duration:const Duration(milliseconds:220),builder:(c,v,child)=>Transform.translate(offset:Offset(0,-25*(1-v)),child:Opacity(opacity:v,child:child)),child:Dismissible(key:ValueKey('$sender$preview'),direction:DismissDirection.horizontal,onDismissed:(_)=>onDismiss(),child:Material(elevation:10,color:panel,borderRadius:BorderRadius.circular(16),child:InkWell(onTap:onTap,borderRadius:BorderRadius.circular(16),child:Padding(padding:const EdgeInsets.all(12),child:Row(children:[PrivateImage(scope:'profile',id:sender,slot:'avatar',size:44),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisSize:MainAxisSize.min,children:[Text(title,style:const TextStyle(fontWeight:FontWeight.bold,color:Colors.white)),Text(subtitle,style:const TextStyle(fontSize:12,color:Colors.white70)),Text(preview,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white))])),IconButton(onPressed:onDismiss,icon:const Icon(Icons.close,color:Colors.white70))]))))));
}
class MuteButton extends StatelessWidget {
 final String thread;const MuteButton({super.key,required this.thread});
 @override Widget build(BuildContext c){final ref=db.collection('users').doc(myUid).collection('mutedThreads').doc(base64Url.encode(utf8.encode(thread)).replaceAll('=',''));return MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:ref.meowSnapshots(),builder:(c,s){final muted=s.data?.exists==true;return IconButton(tooltip:muted?'Ativar notificações':'Silenciar conversa',icon:Icon(muted?Icons.notifications_off:Icons.notifications_none),onPressed:()async{try{if(muted){await ref.delete();}else{await ref.set({'thread':thread});}}catch(e){if(c.mounted)notice(c,e);}});});}
}
class UnreadDmRail extends StatelessWidget {
 final String uid;const UnreadDmRail({super.key,required this.uid});
 @override Widget build(BuildContext c)=>MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('dms').where('members',arrayContains:uid).meowSnapshots(),builder:(c,s)=>Column(children:[for(final d in s.data?.docs??[])UnreadDmRailItem(key:ValueKey(d.id),uid:uid,dm:d),if(s.data?.docs.isNotEmpty==true)const Divider(indent:20,endIndent:20,height:10)]));
}
class UnreadDmRailItem extends StatelessWidget {
 final String uid;final QueryDocumentSnapshot<Map<String,dynamic>> dm;const UnreadDmRailItem({super.key,required this.uid,required this.dm});
 @override Widget build(BuildContext c){final others=List<String>.from(dm.data()['members']??[]).where((x)=>x!=uid);if(others.isEmpty)return const SizedBox.shrink();final other=others.first;return MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:receiptRef('dm:${dm.id}',uid).meowSnapshots(),builder:(c,r)=>MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:dm.reference.collection('messages').orderBy('createdAt',descending:true).limit(100).meowSnapshots(),builder:(c,s){final seen=r.data?.data()?['at'];final unread=s.data?.docs.take(30).any((d){final t=d.data()['createdAt'];return d.data()['authorId']!=uid&&t is Timestamp&&(seen is! Timestamp||t.compareTo(seen)>0);})??false;if(!unread)return const SizedBox.shrink();return Padding(padding:const EdgeInsets.symmetric(vertical:4),child:IconButton(onPressed:()=>Navigator.push(c,CupertinoPageRoute<void>(builder:(_)=>DmChatPage(id:dm.id,other:other,uid:uid))),icon:Stack(clipBehavior:Clip.none,children:[PrivateImage(scope:'profile',id:other,slot:'avatar',size:48),const Positioned(bottom:0,right:0,child:Icon(Icons.circle,color:Color(0xFF39F57A),size:13))]))); }));}
}
class ServerMembers extends StatefulWidget {
 final String server;const ServerMembers({super.key,required this.server});
 @override State<ServerMembers> createState()=>_ServerMembersState();
}
class _ServerMembersState extends State<ServerMembers>{
 final users=<String,Map<String,dynamic>>{};final subs=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? serverSub;Timer? timer;
 @override void initState(){super.initState();serverSub=db.collection('servers').doc(widget.server).meowSnapshots().listen((s){if(!mounted)return;final ids=List<String>.from(s.data()?['members']??[]).toSet();for(final id in subs.keys.toList()){if(!ids.contains(id)){subs.remove(id)?.cancel();users.remove(id);}}for(final id in ids){users.putIfAbsent(id,()=>{});subs.putIfAbsent(id,()=>db.collection('users').doc(id).meowSnapshots().listen((u){if(mounted)setState(()=>users[id]=u.data()??{});}));}setState((){});});timer=Timer.periodic(const Duration(seconds:15),(_){if(mounted)setState((){});});}
 @override void dispose(){timer?.cancel();serverSub?.cancel();for(final s in subs.values){s.cancel();}super.dispose();}
 @override Widget build(BuildContext c){final online=users.entries.where((e)=>currentPresence(e.value)!='offline').toList()..sort((a,b)=>userLabel(a.value).compareTo(userLabel(b.value)));final offline=users.entries.where((e)=>currentPresence(e.value)=='offline').toList()..sort((a,b)=>userLabel(a.value).compareTo(userLabel(b.value)));return SafeArea(child:Column(children:[ListTile(title:const Text('Membros',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),trailing:IconButton(onPressed:()=>Navigator.pop(c),icon:const Icon(Icons.close))),Expanded(child:ListView(children:[for(final group in [online,offline])...[Padding(padding:const EdgeInsets.all(12),child:Text('${identical(group,online)?'ONLINE':'OFFLINE'} — ${group.length}',style:const TextStyle(fontSize:12,color:Colors.white70))),for(final e in group)ListTile(leading:ProfileAvatar(uid:e.key),title:Text(userLabel(e.value)),subtitle:Text(meowPublicId(e.value)),onTap:()=>openProfile(c,e.key))]]))]));}
}
class FriendsPreview extends StatelessWidget {
 final String uid;final Color background,ink;const FriendsPreview({super.key,required this.uid,required this.background,required this.ink});
 Future<List<String>> mutual(List<QueryDocumentSnapshot<Map<String,dynamic>>> docs)async{final checks=await Future.wait(docs.map((d)=>db.collection('users').doc(d.id).collection('following').doc(uid).get()));return checks.where((d)=>d.exists).map((d)=>d.reference.parent.parent!.id).toList();}
 @override Widget build(BuildContext c)=>MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(uid).collection('following').meowSnapshots(),builder:(c,s)=>FutureBuilder<List<String>>(future:MeowMutualChecks.ids(uid,s.data),builder:(c,f){final ids=f.data??[];final preview=ids.take(6).toList();return InkWell(borderRadius:BorderRadius.circular(14),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>uid==myUid?FriendsPage(uid:uid):RelationshipListPage(uid:uid,kind:'friends'))),child:Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:background,borderRadius:BorderRadius.circular(14)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Amigos (${ids.length})',style:TextStyle(fontWeight:FontWeight.bold,color:ink)),if(preview.isNotEmpty)...[const SizedBox(height:8),SizedBox(height:35,width:35.0+(preview.length-1)*25.0,child:Stack(children:[for(var i=0;i<preview.length;i++)Positioned(left:i*25.0,child:PrivateImage(scope:'profile',id:preview[i],slot:'avatar',size:35))]))]])),Icon(Icons.chevron_right,color:ink)])));}));
}
class MeowTabs extends StatefulWidget {
 final int index;final List<Widget> children;const MeowTabs({super.key,required this.index,required this.children});
 @override State<MeowTabs> createState()=>_MeowTabsState();
}
class _MeowTabsState extends State<MeowTabs> with SingleTickerProviderStateMixin {
 late AnimationController controller;int direction=1;
 final visited=<int>{};final paneSizes=<int,Size>{};final paneMedia=<int,MediaQueryData>{};
 @override void initState(){super.initState();visited.add(widget.index);controller=AnimationController(vsync:this,duration:const Duration(milliseconds:200),value:1);}
 @override void didUpdateWidget(covariant MeowTabs old){super.didUpdateWidget(old);if(old.index!=widget.index){visited.add(widget.index);direction=widget.index>old.index?1:-1;controller.forward(from:0);}}
 @override void dispose(){controller.dispose();super.dispose();}
 @override Widget build(BuildContext c)=>LayoutBuilder(builder:(c,b){
   final size=b.biggest;final media=MediaQuery.of(c);
   paneSizes[widget.index]=size;paneMedia[widget.index]=media;
   return ClipRect(child:Stack(fit:StackFit.expand,children:[for(final i in visited) _tab(i,size,media)]));
 });
 Widget _tab(int i,Size size,MediaQueryData media){
   final selected=i==widget.index;final previous=paneSizes[i]??size;
   return Positioned(key:ValueKey(i),left:0,top:0,width:selected?size.width:previous.width,height:selected?size.height:previous.height,
     child:Offstage(offstage:!selected,child:TickerMode(enabled:selected,child:ExcludeFocus(excluding:!selected,
       child:MediaQuery(data:selected?media:(paneMedia[i]??media),child:AnimatedBuilder(animation:controller,
       builder:(c,child){final v=selected?Curves.easeOutCubic.transform(controller.value):1.0;return Transform.translate(offset:Offset(direction*(1-v)*22,0),child:Opacity(opacity:.75+.25*v,child:child));},
       child:RepaintBoundary(child:widget.children[i])))))));
 }
}
class ChannelSlide extends StatefulWidget {
 final bool open;final ValueChanged<bool> onChange;final Widget list,chat;const ChannelSlide({super.key,required this.open,required this.onChange,required this.list,required this.chat});
 @override State<ChannelSlide> createState()=>_ChannelSlideState();
}
class _ChannelSlideState extends State<ChannelSlide> with SingleTickerProviderStateMixin {
 late AnimationController controller;
 bool dragging=false,chatMounted=false;Size? listSize,chatSize;MediaQueryData? listMedia,chatMedia;
 @override void initState(){super.initState();chatMounted=!widget.open;controller=AnimationController(vsync:this,duration:const Duration(milliseconds:210),value:widget.open?1:0)..addStatusListener(status);}
 void status(AnimationStatus value){if(mounted&&(value==AnimationStatus.dismissed||value==AnimationStatus.completed))setState((){});}
 @override void didUpdateWidget(covariant ChannelSlide old){super.didUpdateWidget(old);if(old.open!=widget.open){if(!widget.open)chatMounted=true;controller.animateTo(widget.open?1:0,curve:Curves.easeOutCubic);}}
 @override void dispose(){controller.removeStatusListener(status);controller.dispose();super.dispose();}
 void start(DragStartDetails d){FocusManager.instance.primaryFocus?.unfocus();controller.stop();setState((){dragging=true;chatMounted=true;});}
 void update(DragUpdateDetails d,double width){if(width>0)controller.value=(controller.value+(d.primaryDelta??0)/width).clamp(0.0,1.0).toDouble();}
 void end(DragEndDetails d){final v=d.primaryVelocity??0;final open=v>350?true:v< -350?false:controller.value>.5;setState(()=>dragging=false);widget.onChange(open);controller.animateTo(open?1:0,curve:Curves.easeOutCubic);}
 void cancel(){setState(()=>dragging=false);controller.animateTo(widget.open?1:0,curve:Curves.easeOutCubic);}
 Widget gesture(Widget child,double width,{bool edge=false})=>GestureDetector(behavior:edge?HitTestBehavior.translucent:HitTestBehavior.deferToChild,onHorizontalDragStart:start,onHorizontalDragUpdate:(d)=>update(d,width),onHorizontalDragEnd:end,onHorizontalDragCancel:cancel,child:child);
 @override Widget build(BuildContext c)=>LayoutBuilder(builder:(c,b){
   final size=b.biggest;final media=MediaQuery.of(c);
   final listVisible=widget.open||dragging||controller.value>0;
   final chatVisible=!widget.open||dragging||controller.value<1;
   if(listVisible){listSize=size;listMedia=media;}
   if(chatVisible){chatSize=size;chatMedia=media;}
   final ls=listSize??size;final cs=chatSize??size;
   return ClipRect(child:Stack(fit:StackFit.expand,children:[
     Positioned(left:0,top:0,width:ls.width,height:ls.height,child:Offstage(offstage:!listVisible,child:TickerMode(enabled:listVisible,child:ExcludeFocus(excluding:!widget.open,child:IgnorePointer(ignoring:!widget.open,child:MediaQuery(data:listMedia??media,child:RepaintBoundary(child:gesture(widget.list,size.width)))))))),
     if(chatMounted)Positioned(left:0,top:0,width:cs.width,height:cs.height,child:Offstage(offstage:!chatVisible,child:TickerMode(enabled:chatVisible,child:ExcludeFocus(excluding:widget.open,child:IgnorePointer(ignoring:widget.open,child:MediaQuery(data:chatMedia??media,
       child:AnimatedBuilder(animation:controller,builder:(c,child)=>Transform.translate(offset:Offset(controller.value*size.width,0),child:child),child:RepaintBoundary(child:Material(color:bg,child:widget.chat))))))))),
     if(!widget.open)Positioned(left:0,top:48,bottom:0,width:18,child:gesture(const SizedBox.expand(),size.width,edge:true)),
   ]));
 });
}
class ReplySwipe extends StatefulWidget {
 final Widget child;final VoidCallback onReply;const ReplySwipe({super.key,required this.child,required this.onReply});
 @override State<ReplySwipe> createState()=>_ReplySwipeState();
}
class _ReplySwipeState extends State<ReplySwipe>{double x=0;bool dragging=false,haptic=false;@override Widget build(BuildContext c)=>GestureDetector(onHorizontalDragStart:(_){setState(()=>dragging=true);},onHorizontalDragUpdate:(d){setState(()=>x=(x+(d.primaryDelta??0)*.65).clamp(0.0,90.0).toDouble());if(x>=55&&!haptic){haptic=true;HapticFeedback.selectionClick();}},onHorizontalDragEnd:(_){if(x>=55)widget.onReply();setState((){x=0;dragging=false;haptic=false;});},onHorizontalDragCancel:()=>setState((){x=0;dragging=false;haptic=false;}),child:Stack(alignment:Alignment.centerLeft,children:[if(x>5)Padding(padding:const EdgeInsets.only(left:8),child:Icon(Icons.reply,color:x>=55?purple:Colors.white54)),AnimatedContainer(duration:dragging?Duration.zero:const Duration(milliseconds:160),transform:Matrix4.translationValues(x,0,0),child:widget.child)]));}
class MeowMessageText extends StatelessWidget {
 final String text;final Map<String,Map<String,dynamic>> people;const MeowMessageText({super.key,required this.text,required this.people});
 static final _emojiPattern=RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}]',unicode:true);
 static final _mentions=_meowMentionPattern;
 bool emoji(String c)=>_emojiPattern.hasMatch(c);
 @override Widget build(BuildContext c){if(!_emojiPattern.hasMatch(text)&&!text.contains('@'))return Text(text);final graphemes=text.characters.where((g)=>g.trim().isNotEmpty).toList();final only=graphemes.isNotEmpty&&graphemes.length<=5&&graphemes.every(emoji);if(only)return Text(text,style:const TextStyle(fontSize:48));final spans=<InlineSpan>[];final matcher=_mentions;void plain(String t){if(t.isEmpty)return;if(!_emojiPattern.hasMatch(t)){spans.add(TextSpan(text:t));return;}var buffer=StringBuffer();bool? large;void flush(){if(buffer.isNotEmpty){spans.add(TextSpan(text:buffer.toString(),style:large==true?const TextStyle(fontSize:26):null));buffer=StringBuffer();}}for(final g in t.characters){final next=emoji(g);if(large!=null&&large!=next)flush();large=next;buffer.write(g);}flush();}var last=0;for(final m in matcher.allMatches(text)){plain(text.substring(last,m.start));final name=m.group(1)!.toLowerCase();final found=people.entries.where((e)=>meowSerial(e.value).isNotEmpty&&name=='#${meowSerial(e.value)}');if(found.isNotEmpty){final id=found.first.key;spans.add(WidgetSpan(alignment:PlaceholderAlignment.middle,child:InkWell(onTap:()=>openProfile(c,id),child:Container(padding:const EdgeInsets.symmetric(horizontal:2),decoration:BoxDecoration(color:purple.withOpacity(.18),borderRadius:BorderRadius.circular(4)),child:Text('@${userLabel(found.first.value)}',style:const TextStyle(color:Color(0xFFC4B5FD),fontWeight:FontWeight.w600))))));}else{spans.add(TextSpan(text:m.group(0),style:name=='everyone'?const TextStyle(color:Color(0xFFC4B5FD)):null));}last=m.end;}plain(text.substring(last));return Text.rich(TextSpan(children:spans));}
}
Future<void> saveMeowFile(BuildContext c,Uint8List bytes,String name,bool image)async{
 if(image){await Gal.putImageBytes(bytes,name:name);if(c.mounted)notice(c,'Imagem salva na galeria.');return;}
 final dot=name.lastIndexOf('.');final ext=dot>0?name.substring(dot+1):'';final stem=dot>0?name.substring(0,dot):name;
 final result=await FileSaver.instance.saveAs(name:stem,bytes:bytes,ext:ext,mimeType:MimeType.other);
 if(result!=null&&c.mounted)notice(c,'Arquivo exportado.');
}
class MeowImageViewer extends StatefulWidget {
 final Uint8List bytes;final String name;const MeowImageViewer({super.key,required this.bytes,required this.name});
 @override State<MeowImageViewer> createState()=>_MeowImageViewerState();
}
class _MeowImageViewerState extends State<MeowImageViewer>{final controller=TransformationController();bool saving=false;@override void dispose(){controller.dispose();super.dispose();}@override Widget build(BuildContext c)=>Scaffold(backgroundColor:Colors.black,appBar:AppBar(backgroundColor:Colors.black,title:Text(widget.name,maxLines:1,overflow:TextOverflow.ellipsis),actions:[IconButton(onPressed:saving?null:()async{setState(()=>saving=true);try{await saveMeowFile(c,widget.bytes,widget.name,true);}catch(e){if(c.mounted)notice(c,e);}finally{if(mounted)setState(()=>saving=false);}},icon:const Icon(Icons.download))]),body:Center(child:GestureDetector(onDoubleTap:()=>setState(()=>controller.value=controller.value.getMaxScaleOnAxis()>1?Matrix4.identity():(Matrix4.identity()..scale(2.0))),child:InteractiveViewer(transformationController:controller,minScale:1,maxScale:5,child:Image.memory(widget.bytes,fit:BoxFit.contain,gaplessPlayback:true)))));}
// Crop the original decoded pixels using a fixed frame and user-controlled transform.
class MeowCropPage extends StatefulWidget {
 final Uint8List bytes;final double aspect;final bool circle;const MeowCropPage({super.key,required this.bytes,required this.aspect,required this.circle});
 @override State<MeowCropPage> createState()=>_MeowCropPageState();
}
class _MeowCropPageState extends State<MeowCropPage>{
 ui.Image? image;double zoom=1,startZoom=1;Offset offset=Offset.zero,startOffset=Offset.zero,startPoint=Offset.zero;int turns=0;bool busy=false;Size frame=Size.zero;
 @override void initState(){super.initState();decode();}
 Future<void> decode()async{try{final codec=await ui.instantiateImageCodec(widget.bytes);final f=await codec.getNextFrame();codec.dispose();if(mounted)setState(()=>image=f.image);else f.image.dispose();}catch(e){if(mounted)notice(context,'Não foi possível editar esta imagem.');}}
 @override void dispose(){image?.dispose();super.dispose();}
 double baseScale(){final i=image!;final w=turns.isOdd?i.height:i.width;final h=turns.isOdd?i.width:i.height;return max(frame.width/w,frame.height/h);}
 Offset bounded(Offset p){final i=image!;final scale=baseScale()*zoom;final w=(turns.isOdd?i.height:i.width)*scale;final h=(turns.isOdd?i.width:i.height)*scale;final x=max(0.0,(w-frame.width)/2);final y=max(0.0,(h-frame.height)/2);return Offset(p.dx.clamp(-x,x).toDouble(),p.dy.clamp(-y,y).toDouble());}
 Future<void> confirm()async{if(image==null||busy||frame.isEmpty)return;setState(()=>busy=true);try{final rec=ui.PictureRecorder();final canvas=Canvas(rec);final outScale=min(2048.0/max(frame.width,frame.height),1/(baseScale()*zoom));final w=max(1,(frame.width*outScale).round());final h=max(1,(frame.height*outScale).round());canvas.scale(w/frame.width,h/frame.height);paintCrop(canvas,frame,image!,turns,baseScale()*zoom,offset);final pic=rec.endRecording();final output=await pic.toImage(w,h);final data=await output.toByteData(format:ui.ImageByteFormat.png);output.dispose();pic.dispose();if(data==null)throw Exception('Recorte indisponível');if(mounted)Navigator.pop(context,data.buffer.asUint8List(data.offsetInBytes,data.lengthInBytes));}catch(e){if(mounted)notice(context,e);}finally{if(mounted)setState(()=>busy=false);}}
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Ajustar imagem'),actions:[TextButton(onPressed:busy?null:()=>Navigator.pop(c,widget.bytes),child:const Text('Pular')),IconButton(tooltip:'Confirmar recorte',onPressed:busy||image==null?null:confirm,icon:const Icon(Icons.check))]),body:Column(children:[Expanded(child:Center(child:LayoutBuilder(builder:(c,b){if(image==null)return const Text('Carregando imagem…');final w=min(b.maxWidth-24,(b.maxHeight-24)*widget.aspect);frame=Size(max(1.0,w),max(1.0,w/widget.aspect));return GestureDetector(onScaleStart:(d){startZoom=zoom;startOffset=offset;startPoint=d.localFocalPoint;},onScaleUpdate:(d)=>setState((){zoom=(startZoom*d.scale).clamp(1.0,6.0).toDouble();offset=bounded(startOffset+d.localFocalPoint-startPoint);}),child:ClipRRect(borderRadius:BorderRadius.circular(widget.circle?frame.width/2:8),child:CustomPaint(size:frame,painter:CropPainter(image!,turns,baseScale()*zoom,offset))));}))),const Text('Arraste e use dois dedos para aproximar'),Slider(value:zoom,min:1,max:6,onChanged:image==null?null:(v)=>setState((){zoom=v;offset=bounded(offset);})),SafeArea(top:false,child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[IconButton(tooltip:'Girar',onPressed:busy||image==null?null:()=>setState((){turns=(turns+1)%4;zoom=1;offset=Offset.zero;}),icon:const Icon(Icons.rotate_right)),TextButton(onPressed:busy?null:()=>Navigator.pop(c),child:const Text('Cancelar')),FilledButton(onPressed:busy||image==null?null:confirm,child:const Text('Confirmar'))]))]));
}
void paintCrop(Canvas c,Size size,ui.Image image,int turns,double scale,Offset offset){c.save();c.clipRect(Offset.zero&size);c.translate(size.width/2+offset.dx,size.height/2+offset.dy);c.rotate(turns*pi/2);c.scale(scale);c.drawImage(image,Offset(-image.width/2,-image.height/2),Paint()..filterQuality=FilterQuality.high);c.restore();}
class CropPainter extends CustomPainter{final ui.Image image;final int turns;final double scale;final Offset offset;CropPainter(this.image,this.turns,this.scale,this.offset);@override void paint(Canvas canvas,Size size)=>paintCrop(canvas,size,image,turns,scale,offset);@override bool shouldRepaint(covariant CropPainter old)=>old.image!=image||old.turns!=turns||old.scale!=scale||old.offset!=offset;}


// Meow 0.9.0 — navigation and profile presentation (first development stage).
class MeowAccountHeader extends StatelessWidget {
 final String uid;final VoidCallback? onTap;final bool showPresence;
 const MeowAccountHeader({super.key,required this.uid,this.onTap,this.showPresence=false});
 @override Widget build(BuildContext c)=>InkWell(onTap:onTap,child:MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(uid).meowSnapshots(),builder:(c,s){
  final d=s.data?.data()??{};final presence=currentPresence(d);
  return Row(children:[Stack(clipBehavior:Clip.none,children:[PrivateImage(scope:'profile',id:uid,slot:'avatar',size:38),Positioned(bottom:0,right:0,child:PresenceDot(uid:uid))]),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisSize:MainAxisSize.min,children:[Text(userLabel(d),maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:16,fontWeight:FontWeight.bold)),Text(showPresence?(presenceLabels[presence]??'Offline'):meowPublicId(d),style:const TextStyle(fontSize:12,color:Colors.white54),maxLines:1,overflow:TextOverflow.ellipsis)]))]);
 }));
}
class MeowAccountDrawer extends StatelessWidget {
 final String uid;const MeowAccountDrawer({super.key,required this.uid});
 void go(BuildContext c,Widget page){final nav=Navigator.of(c);nav.pop();nav.push(MaterialPageRoute(builder:(_)=>page));}
 void profile(BuildContext c)=>go(c,Scaffold(appBar:AppBar(title:const Text('Meu perfil')),body:ProfilePage(uid:uid)));
 @override Widget build(BuildContext c)=>Drawer(backgroundColor:panel,child:SafeArea(child:ListView(padding:EdgeInsets.zero,children:[
  MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(uid).meowSnapshots(),builder:(c,s){final d=s.data?.data()??{};return InkWell(onTap:()=>profile(c),child:Stack(children:[
   Container(height:188,decoration:BoxDecoration(gradient:profileGradient(d))),
   if(d['bannerHidden']!=true)Positioned.fill(child:PrivateImage(scope:'profile',id:uid,slot:'banner',size:188,borderRadius:BorderRadius.zero)),
   Positioned.fill(child:DecoratedBox(decoration:BoxDecoration(gradient:LinearGradient(begin:Alignment.topCenter,end:Alignment.bottomCenter,colors:[Colors.transparent,Colors.black.withOpacity(.7)])))),
   Positioned(left:16,right:16,bottom:14,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[PrivateImage(scope:'profile',id:uid,slot:'avatar',size:66),const SizedBox(height:8),Text(userLabel(d),style:const TextStyle(fontSize:22,fontWeight:FontWeight.bold,color:Colors.white)),Text(meowPublicId(d),style:const TextStyle(color:Colors.white70))])),
  ]));}),
  ListTile(leading:const Icon(Icons.person_outline),title:const Text('Meu perfil'),onTap:()=>profile(c)),
  ListTile(leading:const Icon(Icons.edit_outlined),title:const Text('Editar perfil'),onTap:()=>go(c,EditProfilePage(uid:uid))),
  const Divider(),
  ListTile(leading:const Icon(Icons.people_outline),title:const Text('Amigos'),onTap:()=>go(c,FriendsPage(uid:uid))),
  ListTile(leading:const Icon(Icons.person_add_alt_1_outlined),title:const Text('Seguindo'),onTap:()=>go(c,RelationshipListPage(uid:uid,kind:'following'))),
  ListTile(leading:const Icon(Icons.people_outline),title:const Text('Seguidores'),onTap:()=>go(c,RelationshipListPage(uid:uid,kind:'followers'))),
  const Divider(),ListTile(leading:const Icon(Icons.settings_outlined),title:const Text('Configurações'),onTap:()=>go(c,const AppSettingsPage())),
 ])));
}
class MeowBottomBar extends StatelessWidget {
 final int index;final ValueChanged<int> onSelected;
 const MeowBottomBar({super.key,required this.index,required this.onSelected});
 Widget item(int i,IconData icon,String text){final color=index==i?purple:Colors.white54;return Expanded(child:InkWell(onTap:()=>onSelected(i),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Icon(icon,color:color,size:24),const SizedBox(height:4),Text(text,style:TextStyle(fontSize:11,color:color),maxLines:1,overflow:TextOverflow.ellipsis)])));}
 @override Widget build(BuildContext c)=>Material(color:panel,child:SafeArea(top:false,child:SizedBox(height:66,child:Row(children:[item(0,Icons.home,'Home'),item(1,Icons.search,'Discover'),const Expanded(child:Center(child:ExcludeSemantics(child:CircleAvatar(radius:23,backgroundColor:purple,child:Icon(Icons.add,color:Colors.white,size:28))))),item(2,Icons.groups,'Servidores'),item(3,Icons.chat_bubble_outline,'Chat')]))));
}
class MeowDiscover extends StatefulWidget {
 final String uid;const MeowDiscover({super.key,required this.uid});
 @override State<MeowDiscover> createState()=>_MeowDiscoverState();
}
class _MeowDiscoverState extends State<MeowDiscover>{
 final search=TextEditingController();bool busy=false;String? error;List<QueryDocumentSnapshot<Map<String,dynamic>>>? results;int generation=0;
 @override void dispose(){generation++;search.dispose();super.dispose();}
 Future<void> find()async{final q=search.text.trim();final g=++generation;setState((){busy=q.isNotEmpty;error=null;results=null;});if(q.isEmpty)return;
  try{
   final exact=await meowFindUsers(q);final matches={for(final d in exact)d.id:d};
   if(!RegExp(r'^#?[0-9]{1,8}$').hasMatch(q)&&matches.length<20){
    final alternatives={q,q.toLowerCase(),q[0].toUpperCase()+q.substring(1)};
    for(final prefix in alternatives){if(matches.length>=20)break;final r=await db.collection('users').orderBy('displayName').startAt([prefix]).endAt(['$prefix\uf8ff']).limit(20).get();for(final d in r.docs){matches[d.id]=d;}}
   }
   if(mounted&&g==generation)setState(()=>results=matches.values.take(20).toList());
  }catch(_){if(mounted&&g==generation)setState(()=>error='Não foi possível pesquisar. Tente novamente.');}
  finally{if(mounted&&g==generation)setState(()=>busy=false);}
 }
 @override Widget build(BuildContext c)=>Column(children:[Padding(padding:const EdgeInsets.all(12),child:TextField(controller:search,textInputAction:TextInputAction.search,onSubmitted:(_)=>find(),decoration:InputDecoration(hintText:'Nome de exibição ou ID',prefixIcon:const Icon(Icons.search),suffixIcon:IconButton(tooltip:'Pesquisar',icon:const Icon(Icons.arrow_forward),onPressed:find)))),
  Expanded(child:busy?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Text(error!)):results==null?const Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(Icons.people_outline,size:46,color:purple),SizedBox(height:12),Text('Encontre seus amigos')])):results!.isEmpty?const Center(child:Text('Nenhum usuário encontrado.')):ListView(children:[for(final d in results!)ListTile(leading:ProfileAvatar(uid:d.id),title:Text(userLabel(d.data())),subtitle:Text(meowPublicId(d.data())),onTap:()=>openProfile(c,d.id))])),
 ]);
}
class MeowChannelTitle extends StatelessWidget {
 final String server,name;const MeowChannelTitle({super.key,required this.server,required this.name});
 @override Widget build(BuildContext c)=>Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisSize:MainAxisSize.min,children:[Text('# $name',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:17)),MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('servers').doc(server).meowSnapshots(),builder:(c,s){if(!s.hasData||s.hasError)return const SizedBox.shrink();final ids=List<String>.from(s.data?.data()?['members']??[]);return MeowOnlineCount(key:ValueKey(server),ids:ids);})]);
}
class MeowOnlineCount extends StatefulWidget {
 final List<String> ids;const MeowOnlineCount({super.key,required this.ids});
 @override State<MeowOnlineCount> createState()=>_MeowOnlineCountState();
}
class _MeowOnlineCountState extends State<MeowOnlineCount>{
 final users=<String,Map<String,dynamic>>{};final subs=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};Timer? timer;
 void sync(){final visible=TickerMode.of(context);final ids=visible?widget.ids.toSet():<String>{};for(final id in subs.keys.toList()){if(!ids.contains(id)){subs.remove(id)?.cancel();users.remove(id);}}for(final id in ids){subs.putIfAbsent(id,()=>db.collection('users').doc(id).meowSnapshots().listen((d){if(mounted&&subs.containsKey(id))setState(()=>users[id]=d.data()??{});},onError:(Object _){}));}timer?.cancel();timer=visible?Timer.periodic(const Duration(seconds:15),(_){if(mounted)setState((){});}):null;}
 @override void didChangeDependencies(){super.didChangeDependencies();sync();}
 @override void didUpdateWidget(covariant MeowOnlineCount old){super.didUpdateWidget(old);if(old.ids.length!=widget.ids.length||!old.ids.toSet().containsAll(widget.ids))sync();}
 @override void dispose(){timer?.cancel();for(final s in subs.values){s.cancel();}super.dispose();}
 @override Widget build(BuildContext c){final n=users.values.where((d)=>currentPresence(d)!='offline').length;return Row(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.circle,size:9,color:Colors.green),const SizedBox(width:6),Text('$n online',style:const TextStyle(fontSize:12,color:Colors.white54))]);}
}
