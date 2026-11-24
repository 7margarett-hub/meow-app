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
  return n.isNotEmpty?n:d['username']?.toString()??'Usuário';
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
  PrivateMediaCache.clear();activeThread.value=null;
  meowNavigator.currentState?.popUntil((route)=>route.isFirst);
  await FirebaseAuth.instance.signOut();
}

// Cache privado em memoria por sessao. Nunca persiste imagens privadas no disco.
// Compartilha requisicoes entre avatares repetidos e evita novos downloads ao navegar.
class PrivateMediaCache {
  static final Map<String, Future<Uint8List?>> _pending = {};
  static final Map<String, ({Uint8List bytes, DateTime time})> _completed = {};
  static final Map<String, int> _generation = {};
  static const int maxBytes = 40 * 1024 * 1024;
  static const Duration lifetime = Duration(minutes: 5);
  static int _usedBytes = 0;

  static String _key(Uri url) =>
      '${FirebaseAuth.instance.currentUser?.uid ?? ''}|$url';

  static Future<Uint8List?> get(Uri url) {
    final key = _key(url);
    final entry = _completed[key];
    if (entry != null) {
      if (DateTime.now().difference(entry.time) < lifetime) {
        return Future.value(entry.bytes);
      }
      _usedBytes -= entry.bytes.lengthInBytes;
      _completed.remove(key);
    }
    final existing = _pending[key];
    if (existing != null) return existing;
    final generation = _generation[key] ?? 0;
    final task = _download(url, key, generation);
    _pending[key] = task;
    task.whenComplete(() {
      if (identical(_pending[key], task)) _pending.remove(key);
    });
    return task;
  }

  static Future<Uint8List?> _download(Uri url, String key, int generation) async {
    try {
      final response = await http.get(url, headers: await authHeaders())
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        debugPrint('Meow media: HTTP ${response.statusCode} em ${url.path}');
        return null;
      }
      final bytes = response.bodyBytes;
      if (bytes.isEmpty) {
        debugPrint('Meow media: resposta vazia em ${url.path}');
        return null;
      }
      if ((_generation[key] ?? 0) == generation && bytes.lengthInBytes <= maxBytes) {
        while (_completed.isNotEmpty && _usedBytes + bytes.lengthInBytes > maxBytes) {
          final oldest = _completed.keys.first;
          _usedBytes -= _completed.remove(oldest)!.bytes.lengthInBytes;
        }
        _completed[key] = (bytes: bytes, time: DateTime.now());
        _usedBytes += bytes.lengthInBytes;
      }
      return bytes;
    } catch (e) {
      debugPrint('Meow media: falha no download (${url.path}): $e');
      return null;
    }
  }

  static void invalidate(Uri url) {
    final key = _key(url);
    _generation[key] = (_generation[key] ?? 0) + 1;
    final old = _completed.remove(key);
    if (old != null) _usedBytes -= old.bytes.lengthInBytes;
    _pending.remove(key);
  }

  static void clear() {
    for (final key in {..._pending.keys, ..._completed.keys}) {
      _generation[key] = (_generation[key] ?? 0) + 1;
    }
    _completed.clear();
    _pending.clear();
    _usedBytes = 0;
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
),), home:StreamBuilder<User?>(stream:FirebaseAuth.instance.authStateChanges(), builder:(c, s) => s.connectionState == ConnectionState.waiting ? const LoadingCat() : s.data == null ? const LoginPage() : const SocialHome()),
);
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
        final u=await FirebaseAuth.instance.createUserWithEmailAndPassword(email:loginEmail(n), password:password.text);
        await db.collection('users').doc(u.user!.uid).set({
          'username':n,
          'createdAt':FieldValue.serverTimestamp(),
          'presence':'online',
          'customStatus':''
}
);
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
          return s.data==null?placeholder:Image.memory(s.data!, fit:BoxFit.cover, gaplessPlayback:true, errorBuilder:(c,
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
      if(f==null)return;
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
        if(result==null)return;
        if(!identical(result,bytes))mime='image/png';
        bytes=result;
      }
      if(bytes.length>limit)throw Exception('Imagem acima do limite após edição.');
      final headers = await authHeaders();
      headers['Content-Type'] = mime;
      final r=await http.put(mediaUrl(widget.scope, widget.id, widget.slot), headers:headers,
      body:bytes
).timeout(const Duration(seconds:120));
      if(r.statusCode!=200)throw Exception('Upload falhou: ${r.statusCode} ${r.body}');
      if(widget.scope=='profile'&&widget.slot=='banner')await db.collection('users').doc(widget.id).update({'bannerHidden':false});
      if(widget.scope=='profile'&&widget.slot=='background')await db.collection('users').doc(widget.id).update({'backgroundEnabled':true});
      PrivateMediaCache.invalidate(mediaUrl(widget.scope,widget.id,widget.slot));
      changedImage.value=null;
      changedImage.value=mediaUrl(widget.scope, widget.id, widget.slot);
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

class PresenceDot extends StatefulWidget {
  final String uid;
  const PresenceDot({super.key,required this.uid});
  @override State<PresenceDot> createState()=>_PresenceDotState();
}
class _PresenceDotState extends State<PresenceDot>{
  Timer? timer;
  late Stream<DocumentSnapshot<Map<String,dynamic>>> stream;
  @override void initState(){super.initState();stream=db.collection('users').doc(widget.uid).snapshots();timer=Timer.periodic(const Duration(seconds:15),(_){if(mounted)setState((){});});}
  @override void didUpdateWidget(covariant PresenceDot old){super.didUpdateWidget(old);if(old.uid!=widget.uid)stream=db.collection('users').doc(widget.uid).snapshots();}
  @override void dispose(){timer?.cancel();super.dispose();}
  @override Widget build(BuildContext c)=>StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:stream,builder:(c,s)=>Container(width:13,height:13,decoration:BoxDecoration(color:presenceColor(currentPresence(s.data?.data())),shape:BoxShape.circle,border:Border.all(color:bg,width:2))));
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
    body: StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(
      stream: db.collection('users').doc(uid).collection(kind=='friends'?'following':kind).snapshots(),
      builder: (context,s) {
        if(s.hasError)return Center(child:Text('Erro: ${s.error}'));
        if(!s.hasData)return const Center(child:CircularProgressIndicator());
        final docs=s.data!.docs;
        if(kind=='friends')return MutualFriendsList(uid:uid);
        if(kind!='friends')return ListView(children:[for(final d in docs) ListTile(
          leading: ProfileAvatar(uid:d.id), title: UserDisplayName(uid:d.id),
          onTap:()=>openProfile(context,d.id))]);
        return ListView(children:[for(final d in docs) StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
          stream:db.collection('users').doc(d.id).collection('following').doc(uid).snapshots(),
          builder:(context,other)=>other.data?.exists==true?ListTile(
            leading:ProfileAvatar(uid:d.id),title:UserDisplayName(uid:d.id),
            onTap:()=>openProfile(context,d.id)):const SizedBox.shrink())]);
      }));
}
class UserDisplayName extends StatelessWidget {
  final String uid;
  const UserDisplayName({super.key,required this.uid});
  @override Widget build(BuildContext context)=>StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
    stream:db.collection('users').doc(uid).snapshots(),
    builder:(context,s){final d=s.data?.data()??{};final name=d['displayName']?.toString()??'';return Text(name.isNotEmpty?name:d['username']?.toString()??'Usuário');});
}
class FollowButton extends StatelessWidget {
  final String target;
  const FollowButton({super.key,required this.target});
  @override Widget build(BuildContext context)=>StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
    stream:db.collection('users').doc(myUid).collection('following').doc(target).snapshots(),
    builder:(context,s)=>FilledButton.icon(
      onPressed:()=>toggleFollow(target,s.data?.exists==true).catchError((Object e){if(context.mounted)notice(context,e);}),
      icon:Icon(s.data?.exists==true?Icons.person_remove:Icons.person_add),
      label:Text(s.data?.exists==true?'Deixar de seguir':'Seguir')));
}
class RelationshipCounters extends StatelessWidget {
  final String uid;
  const RelationshipCounters({super.key,required this.uid});
  @override Widget build(BuildContext context)=>Row(children:[
    for(final kind in ['followers','following','friends']) Expanded(child:StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(
      stream:db.collection('users').doc(uid).collection(kind=='friends'?'following':kind).snapshots(),
      builder:(context,s){
        if(kind=='friends')return FutureBuilder<int>(future: _mutualCount(uid,s.data?.docs??[]),builder:(context,c)=>_counter(context,kind,c.data??0));
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

class ProfilePage extends StatelessWidget {
  final String uid; final bool expanded; final ScrollController? scrollController;
  const ProfilePage({super.key,required this.uid,this.expanded=false,this.scrollController});
  @override Widget build(BuildContext c)=>StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(uid).snapshots(),builder:(c,s){
    if(s.hasError)return const Center(child:Text('Perfil indisponível.'));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    final d=s.data!.data()??{}; final own=uid==FirebaseAuth.instance.currentUser?.uid;
    final base=meowColor(d['themeColorA'],panel);final end=d['themeGradient']==true?meowColor(d['themeColorB'],base):base;
    final ink=d['backgroundEnabled']==true?Colors.white:Color.lerp(base,end,.5)!.computeLuminance()>.42?Colors.black:Colors.white;
    final accent=Color.lerp(base,ink,.22)!;final cardColor=Color.lerp(base,ink,.09)!.withOpacity(.88);
    return Theme(data:Theme.of(c).copyWith(textTheme:Theme.of(c).textTheme.apply(bodyColor:ink,displayColor:ink),colorScheme:Theme.of(c).colorScheme.copyWith(primary:ink,onPrimary:base,surface:cardColor,onSurface:ink)),child:Container(decoration:BoxDecoration(gradient:profileGradient(d)),child:Stack(children:[
      if(d['backgroundEnabled']==true)Positioned.fill(top:d['bannerHidden']==true?0:180,child:ProfileBackground(uid:uid)),
      ListView(controller:scrollController,children:[Stack(children:[const SizedBox(height:230,width:double.infinity),ProfileBanner(uid:uid,data:d),Positioned(left:18,bottom:0,child:Container(padding:const EdgeInsets.all(4),decoration:BoxDecoration(color:base,shape:BoxShape.circle),child:Stack(children:[PrivateImage(scope:'profile',id:uid,slot:'avatar',size:88),Positioned(bottom:2,right:2,child:PresenceDot(uid:uid))]))) ]),
      Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(userLabel(d),style:TextStyle(fontSize:25,fontWeight:FontWeight.bold,color:ink)),const SizedBox(height:4),Wrap(crossAxisAlignment:WrapCrossAlignment.center,spacing:8,children:[Text('@${d['username']??'meow'}',style:TextStyle(color:ink.withOpacity(.75))),if((d['pronouns']?.toString()??'').isNotEmpty)Container(padding:const EdgeInsets.symmetric(horizontal:9,vertical:3),decoration:BoxDecoration(color:cardColor,borderRadius:BorderRadius.circular(20)),child:Text(d['pronouns'].toString(),style:TextStyle(color:ink,fontSize:12)))]),
      if((d['customStatus']?.toString()??'').isNotEmpty)Padding(padding:const EdgeInsets.only(top:12),child:Text(d['customStatus'].toString(),style:TextStyle(color:ink))),const SizedBox(height:16),
      Container(decoration:BoxDecoration(color:cardColor,borderRadius:BorderRadius.circular(15),border:Border.all(color:accent)),padding:const EdgeInsets.symmetric(vertical:8),child:RelationshipCounters(uid:uid)),
      if((d['bio']?.toString()??'').isNotEmpty)...[const SizedBox(height:18),Text('SOBRE MIM',style:TextStyle(color:ink.withOpacity(.7),fontSize:12,fontWeight:FontWeight.bold)),const SizedBox(height:6),Text(d['bio'].toString(),style:TextStyle(color:ink))],const SizedBox(height:20),
      if(own)SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>EditProfilePage(uid:uid))),icon:const Icon(Icons.edit),label:const Text('Editar perfil e status'))),
      if(!own)...[FollowButton(target:uid),SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:()async{if(expanded){Navigator.pop(c,'dm');}else{await openDm(c,uid);}},icon:const Icon(Icons.message),label:const Text('Enviar mensagem')))],
      const SizedBox(height:12),FriendsPreview(uid:uid,background:cardColor,ink:ink),
      if(own&&!expanded)TextButton.icon(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const AppSettingsPage())),icon:const Icon(Icons.settings),label:const Text('Configurações do aplicativo')),
      ]))])])));
  });
}
class AppSettingsPage extends StatelessWidget {
  const AppSettingsPage({super.key});
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Configurações')),
    body:ListView(children:[
      ListTile(leading:const Icon(Icons.person),title:const Text('Conta'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Conta')),body:ListView(children:[
        ListTile(title:const Text('Editar perfil'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>EditProfilePage(uid:myUid)))),
        ListTile(title:const Text('Alterar senha'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const ChangePasswordPage()))), ListTile(title:const Text('Sair da conta'),onTap:()=>logoutMeow(c))]))))),
      ListTile(leading:const Icon(Icons.notifications),title:const Text('Notificações'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const NotificationSettingsPage()))),
      ListTile(leading:const Icon(Icons.storage),title:const Text('Armazenamento'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Armazenamento')),body:ListTile(title:const Text('Limpar cache de imagens'),onTap:(){PrivateMediaCache.clear();notice(c,'Cache limpo.');}))))),
      ListTile(leading:const Icon(Icons.info),title:const Text('Sobre o Meow'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Sobre o Meow')),body:const Center(child:Text('Meow • Beta')))))),
    ]));
}
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});
  @override State<NotificationSettingsPage> createState()=>_NotificationSettingsPageState();
}
class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Notificações')),body:StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(myUid).collection('preferences').doc('notifications').snapshots(),builder:(c,s){
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
      body:StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(stream:db.collection('users').doc(widget.uid).snapshots(),
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

class ServerHeader extends StatelessWidget {
  final String id;
  const ServerHeader({
    super.key,
    required this.id
}
);
  @override Widget build(BuildContext c)=>StreamBuilder<DocumentSnapshot<Map<String,
  dynamic>>>(stream:db.collection('servers').doc(id).snapshots(), builder:(c, s){
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
    @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Configurações do servidor')),
      body:StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(stream:db.collection('servers').doc(id).snapshots(),
      builder:(c, s){
        if(!s.hasData)return const Center(child:CircularProgressIndicator());
        final d=s.data?.data()??{
}
;
        final owner=d['ownerId']==myUid;
          return ListView(children:[PrivateImage(scope:'server', id:id, slot:'banner', size:160), const SizedBox(height:16),
            Center(child:PrivateImage(scope:'server', id:id, slot:'avatar', size:88)), Padding(padding:const EdgeInsets.all(18),
              child:Column(children:[Text(d['name']?.toString()??'Servidor', style:const TextStyle(fontSize:22)),
                const SizedBox(height:18), if(owner) OutlinedButton.icon(icon:const Icon(Icons.edit),label:const Text('Renomear servidor'),onPressed:()async{final v=await showTextPrompt(c,'Nome do servidor',d['name']?.toString()??'');if(v!=null&&v.isNotEmpty)await db.collection('servers').doc(id).update({'name':v});}), const SizedBox(height:12), if(owner) ListTile(title:const Text('Organizar categorias e canais'),trailing:const Icon(Icons.chevron_right),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ServerOrganizationPage(id:id)))), if(owner||(d['adminIds'] is List&&(d['adminIds'] as List).contains(myUid)))ListTile(title:const Text('Emojis e figurinhas'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ExpressionSettings(server:id)))),if(owner) SwitchListTile(title:const Text('Permitir @everyone a todos os membros'),value:d['everyoneEnabled']==true,onChanged:(v)async{try{await db.collection('servers').doc(id).update({'everyoneEnabled':v});}catch(e){if(c.mounted)notice(c,e);}}),if(owner) ChangeImage('server', id, 'avatar', 'Trocar ícone (8 MiB)'),if(owner) ChangeImage('server',id,'banner','Trocar banner (15 MiB)'),if(owner) OutlinedButton.icon(onPressed:()=>confirmServerDelete(c,id),icon:const Icon(Icons.delete),label:const Text('Excluir servidor')),if(!owner)OutlinedButton.icon(onPressed:()=>confirmLeaveServer(c,id),icon:const Icon(Icons.logout),label:const Text('Sair do servidor'))
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
    body:StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('servers').doc(id).collection('channels').snapshots(),
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
      notificationOverlay=OverlayEntry(builder:(c)=>Positioned(top:MediaQuery.paddingOf(c).top+8,left:12,right:12,child:MeowNotificationBanner(key:ValueKey(path),sender:sender,title:userLabel(u),subtitle:message.data['kind']=='reply'?'Respondeu à sua mensagem':message.data['kind']=='mention'?'Mencionou você':'Mensagem privada',preview:text.isEmpty?'Nova mensagem':text,onDismiss:dismissNotification,onTap:(){dismissNotification();openNotification(message);} )));
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
        if(others.isNotEmpty&&mounted)nav.push(MaterialPageRoute(builder:(_)=>DmChatPage(id:parts[1],other:others.first,uid:myUid,initialMessageId:parts.last)));
      }else{
        final ch=(await db.collection('servers').doc(parts[1]).collection('channels').doc(parts[3]).get()).data();
        if(mounted)nav.push(MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:Text('# ${ch?['name']??'canal'}'),actions:[MuteButton(thread:'server:${parts[1]}:${parts[3]}')]),body:MessageThread(collection:db.collection('servers').doc(parts[1]).collection('channels').doc(parts[3]).collection('messages'),uid:myUid,serverId:parts[1],threadId:'server:${parts[1]}:${parts[3]}',initialMessageId:parts.last))));
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
), IconButton(onPressed:joinInvite, icon:const Icon(Icons.group_add)), Expanded(child:StreamBuilder<QuerySnapshot<Map<String,
      dynamic>>>(stream:db.collection('servers').where('members', arrayContains:myUid).snapshots(), builder:(c,
    s
)=>ListView(children:[UnreadDmRail(uid:myUid),for(final d in s.data?.docs??[])Padding(key:ValueKey(d.id),padding:const EdgeInsets.symmetric(vertical:5),
      child:IconButton(tooltip:d.data()['name']?.toString()??'Servidor', onPressed:()=>setState((){
        serverId=d.id;
        channelId=null;
        showingChannels=true;
}
), icon:Stack(clipBehavior:Clip.none,children:[PrivateImage(scope:'server', id:d.id, slot:'avatar', size:48),Positioned(right:-2,bottom:-2,child:ServerUnreadDot(key:ValueKey(d.id),serverId:d.id,uid:myUid))]))
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
  Widget serverContent(){
    if(serverId==null)return Row(children:[rail(), const Expanded(child:Center(child:Text('Crie um servidor ou entre com um convite.')))]);
    return StreamBuilder<QuerySnapshot<Map<String,
      dynamic>>>(key:ValueKey(serverId), stream:db.collection('servers').doc(serverId).collection('channels').snapshots(),
      builder:(c, s){
        if(s.hasError)return Center(child:Text('Erro: ${s.error}'));
        final docs=s.data?.docs??[];
        final active=docs.any((d)=>d.id==channelId)?channelId:(docs.isEmpty?null:docs.first.id);
        final activeDoc=docs.where((d)=>d.id==active);
        final activeName=activeDoc.isEmpty?'canal':activeDoc.first.data()['name']?.toString()??'canal';
        return ChannelSlide(open:showingChannels,onChange:(v)=>setState(()=>showingChannels=v),
          list:Row(children:[rail(),Expanded(child:ColoredBox(color:panel,child:Column(children:[ServerHeader(id:serverId!),Row(children:[const Expanded(child:Padding(padding:EdgeInsets.all(12),child:Text('Canais',style:TextStyle(fontSize:18)))),IconButton(onPressed:createChannel,icon:const Icon(Icons.add)),IconButton(onPressed:createInvite,icon:const Icon(Icons.share))]),Expanded(child:channelList(docs))])))]),
          chat:Column(children:[ListTile(leading:IconButton(icon:const Icon(Icons.menu),onPressed:()=>setState(()=>showingChannels=true)),title:InkWell(onTap:()=>showGeneralDialog(context:context,barrierDismissible:true,barrierLabel:'Membros',transitionDuration:const Duration(milliseconds:220),pageBuilder:(c,_,__)=>Align(alignment:Alignment.centerRight,child:Material(color:panel,child:SizedBox(width:min(MediaQuery.sizeOf(c).width*.85,350.0),child:ServerMembers(server:serverId!)))),transitionBuilder:(c,a,_,child)=>SlideTransition(position:Tween(begin:const Offset(1,0),end:Offset.zero).animate(a),child:child)),child:Text('# $activeName')),trailing:active==null?null:MuteButton(thread:'server:$serverId:$active')),Expanded(child:active==null?const Center(child:Text('Sem canais')):MessageThread(key:ValueKey('$serverId/$active'),collection:db.collection('servers').doc(serverId).collection('channels').doc(active).collection('messages'),uid:myUid,serverId:serverId,threadId:'server:$serverId:$active',visible:!showingChannels&&tab==0))]));
      });
  }
  @override Widget build(BuildContext c)=>PopScope(canPop:!(tab==0&&!showingChannels),onPopInvokedWithResult:(didPop,result){if(!didPop&&tab==0&&!showingChannels)setState(()=>showingChannels=true);},child:Scaffold(appBar:AppBar(title:const MeowTitle()),body:Column(children:[Expanded(child:MeowTabs(index:tab,children:[serverContent(),DmListPage(uid:myUid),ProfilePage(uid:myUid)])),if(tab!=0||showingChannels)NavigationBar(height:70,selectedIndex:tab,onDestinationSelected:(i)=>setState(()=>tab=i),destinations:const [NavigationDestination(icon:Icon(Icons.tag),label:'Canais'),NavigationDestination(icon:Icon(Icons.chat_bubble_outline),label:'DMs'),NavigationDestination(icon:Icon(Icons.person),label:'Perfil')])])));
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
      Navigator.push(context, MaterialPageRoute(
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
  Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:TextField(decoration:const InputDecoration(hintText:'Buscar por nome ou @usuário',prefixIcon:Icon(Icons.search)),onChanged:(v)=>setState(()=>query=v.trim().toLowerCase()))),
  Expanded(child:StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('dms').where('members',arrayContains:widget.uid).snapshots(),builder:(c,s){
    if(s.hasError)return Center(child:Text('Erro: ${s.error}'));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    if(s.data!.docs.isEmpty)return const Center(child:Text('Abra o perfil de alguém para conversar.'));
    return ListView(children:[for(final d in s.data!.docs) Builder(builder:(c){
      final others=List<String>.from(d.data()['members']??[]).where((x)=>x!=widget.uid).toList();
      if(others.isEmpty)return const SizedBox.shrink();
      final other=others.first;
      return StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(other).snapshots(),builder:(c,u){
        final data=u.data?.data()??{};
        final name=((data['displayName']?.toString()??'').isNotEmpty?data['displayName']:data['username']??'Usuário').toString();
        final username=data['username']?.toString()??'';
        if(query.isNotEmpty&&!name.toLowerCase().contains(query)&&!username.toLowerCase().contains(query.replaceFirst('@','')))return const SizedBox.shrink();
        return ListTile(leading:ProfileAvatar(uid:other),title:Text(name),subtitle:DmPreview(id:d.id,uid:widget.uid),trailing:ThreadUnreadDot(threadId:'dm:${d.id}',uid:widget.uid,collection:d.reference.collection('messages')),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>DmChatPage(id:d.id,other:other,uid:widget.uid))));
      });
    })]);
  }))]);
}
class DmChatPage extends StatelessWidget {
 final String id,other,uid;final String? initialMessageId;
 const DmChatPage({super.key,required this.id,required this.other,required this.uid,this.initialMessageId});
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:UserDisplayName(uid:other),actions:[MuteButton(thread:'dm:$id')]),body:DmPermissionGate(id:id,uid:uid,other:other,initialMessageId:initialMessageId));
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
    return StreamBuilder<DocumentSnapshot<Map<String,
    dynamic>>>(stream:receiptRef(threadId, uid).snapshots(), builder:(c, r){
      final seen=r.data?.data()?['at'] as Timestamp?;
      return StreamBuilder<QuerySnapshot<Map<String,
        dynamic>>>(stream:collection.orderBy('createdAt', descending:true).limit(100).snapshots(), builder:(c,
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
  String? username; Map<String,Map<String,dynamic>> people={}; bool everyoneAllowed=false;
  StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? memberSub;
  final memberSubscriptions=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};
  late Stream<QuerySnapshot<Map<String,dynamic>>> messages;
  
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);messages=widget.collection.orderBy('createdAt',descending:true).limit(100).snapshots();memberSub=widget.serverId==null?widget.collection.parent!.snapshots().listen(updateMembers):db.collection('servers').doc(widget.serverId).snapshots().listen(updateMembers);if(widget.initialMessageId!=null)loadTarget();}
  Future<void> loadTarget()async {try{final target=await widget.collection.doc(widget.initialMessageId).get();final t=target.data()?['createdAt'];if(t is Timestamp&&mounted){final recent=await widget.collection.orderBy('createdAt',descending:true).limit(100).get();if(!recent.docs.any((d)=>d.id==target.id)&&mounted)setState((){anchored=true;jumped=false;messages=widget.collection.orderBy('createdAt',descending:true).startAt([t]).limit(100).snapshots();});}}catch(_){} }
  void updateMembers(DocumentSnapshot<Map<String,dynamic>> snapshot){if(!mounted)return;final d=snapshot.data()??{};final ids=List<String>.from(d['members']??[]).toSet();everyoneAllowed=d['ownerId']==widget.uid||d['everyoneEnabled']==true;for(final id in memberSubscriptions.keys.toList()){if(!ids.contains(id)){memberSubscriptions.remove(id)?.cancel();people.remove(id);}}for(final id in ids){memberSubscriptions.putIfAbsent(id,()=>db.collection('users').doc(id).snapshots().listen((u){if(mounted)setState(()=>people[id]=u.data()??{});}));}setState((){});}
  @override void didChangeDependencies(){super.didChangeDependencies();final route=ModalRoute.of(context);if(route!=null)meowRouteObserver.subscribe(this,route);routeActive=route?.isCurrent??true;updateActive();}
  @override void didUpdateWidget(covariant MessageThread old){super.didUpdateWidget(old);if(old.visible!=widget.visible){updateActive();lastMarkedMessage=null;}}
  void updateActive(){if(widget.visible&&routeActive&&foreground){activeThread.value=widget.threadId;}else if(activeThread.value==widget.threadId){activeThread.value=null;}}
  @override void didPush(){routeActive=true;updateActive();} @override void didPopNext(){routeActive=true;updateActive();if(mounted)setState(()=>lastMarkedMessage=null);} @override void didPushNext(){routeActive=false;updateActive();} @override void didPop(){routeActive=false;updateActive();}
  @override void didChangeAppLifecycleState(AppLifecycleState state){foreground=state==AppLifecycleState.resumed;updateActive();if(foreground&&mounted)setState(()=>lastMarkedMessage=null);}
  void replyTo(QueryDocumentSnapshot<Map<String,dynamic>> doc){final d=doc.data();setState((){replyId=doc.id;replyText=d['text']?.toString()??'';replyAuthor=d['author']?.toString()??'Usuário';replyAuthorId=d['authorId']?.toString();});}
  String? get mentionQuery=>RegExp(r'(?:^|\s)@([a-zA-Z0-9_]*)$').firstMatch(input.text)?.group(1)?.toLowerCase();
  void selectMention(String name){final match=RegExp(r'@([a-zA-Z0-9_]*)$').firstMatch(input.text);if(match==null)return;input.text=input.text.replaceRange(match.start,match.end,'@$name ');input.selection=TextSelection.collapsed(offset:input.text.length);typingChanged(input.text);}
  bool highlighted(Map<String,dynamic> d){if(d['authorId']==widget.uid)return false;final names=mentionNames(d['text']?.toString()??'');return d['replyAuthorId']==widget.uid||names.contains(people[widget.uid]?['username'])||(names.contains('everyone')&&d['everyoneMention']==true);}
  Widget mentionSuggestions(){final q=mentionQuery;if(q==null)return const SizedBox.shrink();final suggestions=people.entries.where((e)=>e.key!=widget.uid&&(e.value['username']?.toString()??'').startsWith(q)).take(5);return ConstrainedBox(constraints:const BoxConstraints(maxHeight:230),child:Material(color:panel,child:ListView(shrinkWrap:true,children:[if(widget.serverId!=null&&everyoneAllowed&&'everyone'.startsWith(q))ListTile(dense:true,title:const Text('@everyone'),onTap:()=>selectMention('everyone')),for(final e in suggestions)ListTile(dense:true,leading:PrivateImage(scope:'profile',id:e.key,slot:'avatar',size:30),title:Text(userLabel(e.value)),subtitle:Text('@${e.value['username']}'),onTap:()=>selectMention(e.value['username'].toString()))])));}

  final input=TextEditingController();
  bool sending=false;
  Timestamp? lastMarkedMessage;
  Timer? typingTimer;
  DateTime? lastTyping;
  DocumentReference<Map<String,dynamic>> get typingRef=>widget.collection.parent!.collection('typing').doc(widget.uid);
  Future<void> stopTyping() async {typingTimer?.cancel();lastTyping=null;try{await typingRef.delete();}catch(_){} }
  void typingChanged(String value){if(mounted)setState((){});if(value.trim().isEmpty){stopTyping();return;}final now=DateTime.now();if(lastTyping==null||now.difference(lastTyping!).inMilliseconds>1500){lastTyping=now;typingRef.set({'at':FieldValue.serverTimestamp()}).catchError((Object _){});}typingTimer?.cancel();typingTimer=Timer(const Duration(seconds:3),stopTyping);}

  String? replyId,
  replyText,
  replyAuthor,replyAuthorId;
  @override void dispose(){
    meowRouteObserver.unsubscribe(this);WidgetsBinding.instance.removeObserver(this);memberSub?.cancel();for(final sub in memberSubscriptions.values){sub.cancel();}if(activeThread.value==widget.threadId)activeThread.value=null;
    stopTyping();
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
      await stopTyping();
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
            await for (final chunk in file.openRead()) {
              request.sink.add(chunk);transferred+=chunk.length;
              if(mounted)setState(()=>uploadProgress=(transferred/length).clamp(0.0,1.0).toDouble());
            }
            await request.sink.close();
          } catch (e, st) {
            request.sink.addError(e, st);
            rethrow;
          }
        }();
        final response = await client.send(request).timeout(const Duration(minutes: 3));
        final result = await http.Response.fromStream(response)
            .timeout(const Duration(minutes: 3));
        await producer;
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
    @override Widget build(BuildContext c)=>Column(children:[if(anchored)TextButton(onPressed:()=>setState((){anchored=false;jumped=true;messages=widget.collection.orderBy('createdAt',descending:true).limit(100).snapshots();}),child:const Text('Voltar às mensagens recentes')),Expanded(child:StreamBuilder<QuerySnapshot<Map<String,
      dynamic>>>(stream:messages,
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
          return ScrollablePositionedList.builder(itemScrollController:itemScroll,reverse:true,padding:const EdgeInsets.all(12),itemCount:docs.length,itemBuilder:(c,
        i
){
          final doc=docs[i],
          d=doc.data();
          final author=d['authorId']?.toString()??'';
          final attachment=d['attachment'];
          final older=i+1<docs.length?docs[i+1].data():null;
          final grouped=older!=null && older['authorId']==author && older['createdAt'] is Timestamp && d['createdAt'] is Timestamp && (d['createdAt'] as Timestamp).toDate().difference((older['createdAt'] as Timestamp).toDate()).inMinutes.abs()<5;
          final when=d['createdAt'] is Timestamp?formatMeowTime((d['createdAt'] as Timestamp).toDate()):'Enviando...';
            return ReplySwipe(key:ValueKey(doc.id),onReply:()=>replyTo(doc),child:InkWell(onLongPress:()=>options(doc), child:Container(decoration:highlighted(d)?const BoxDecoration(color:Color(0x22FFC107),border:Border(left:BorderSide(color:Colors.amber,width:3))):null,padding:EdgeInsets.symmetric(vertical:grouped?2:7,horizontal:4),
              child:Row(crossAxisAlignment:CrossAxisAlignment.start, children:[grouped?const SizedBox(width:40):ProfileAvatar(uid:author), const SizedBox(width:10),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[if(!grouped)Row(children:[Flexible(child:InkWell(onTap:()=>openProfile(c,author),child:Text(d['author']?.toString()??'Usuário',style:const TextStyle(fontWeight:FontWeight.bold,color:purple)))),const SizedBox(width:8),Text(when,style:const TextStyle(fontSize:11,color:Colors.white54))]), if(d['replyToId']!=null)Text('↳ ${d['replyAuthor']??''}: ${d['replyText']??''}', maxLines:2,
              overflow:TextOverflow.ellipsis, style:const TextStyle(color:Colors.white60, fontSize:12)
), if((d['text']?.toString()??'').isNotEmpty)MeowMessageText(text:d['text'].toString(),people:people), if(attachment is Map&&attachment['id'] is String)AttachmentView(key:ValueKey(attachment['id']),attachment:attachment),if(d['expression'] is Map) ExpressionImage(data:Map<String,dynamic>.from(d['expression'] as Map),message:doc.reference.path,size:(d['expression'] as Map)['kind']=='emoji'&&(d['text']?.toString()??'').isNotEmpty?26.0:null),ReactionBar(ref:doc.reference,uid:widget.uid),
              if(d['editedAt']!=null)const Text('(editada)', style:TextStyle(fontSize:11, color:Colors.white54))
]))
])
)));
}
);
}
)
), if(uploading)LinearProgressIndicator(value:uploadProgress),TypingLabel(collection:widget.collection.parent!.collection('typing'),uid:widget.uid), mentionSuggestions(), if(replyId!=null)ListTile(dense:true, title:Text('Respondendo a $replyAuthor: $replyText', maxLines:1,
  overflow:TextOverflow.ellipsis
), trailing:IconButton(icon:const Icon(Icons.close), onPressed:()=>setState((){
    replyId=null;
    replyText=null;
    replyAuthor=null;replyAuthorId=null;
}
))), SafeArea(top:false, child:Padding(padding:const EdgeInsets.all(8), child:Row(children:[IconButton(tooltip:'Anexar arquivo',
  onPressed:(sending||uploading)?null:attach, icon:Icon(uploading?Icons.hourglass_top:Icons.add_circle_outline)
), Expanded(child:TextField(controller:input, maxLength:2000, maxLines:4, minLines:1, decoration:const InputDecoration(hintText:'Mensagem',
  counterText:''
), onChanged:typingChanged,onSubmitted:(_){if(!uploading)send();})), IconButton(tooltip:'Emojis e figurinhas',icon:const Icon(Icons.emoji_emotions_outlined),onPressed:(sending||uploading)?null:()async{final v=await pickExpression(context);if(!mounted||v==null)return;if(v is String){input.text+=v;typingChanged(input.text);}else if(v is Map<String,dynamic>){await send(expression:v);}}), IconButton(onPressed:(sending||uploading)?null:()=>send(), icon:const Icon(Icons.send,
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
 @override Widget build(BuildContext c){final name=widget.attachment['name']?.toString()??'Arquivo';return Container(margin:const EdgeInsets.only(top:5),constraints:const BoxConstraints(maxWidth:320),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(12),border:Border.all(color:Colors.white12)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[if(isImage)FutureBuilder<Uint8List?>(future:imageFuture,builder:(c,s){if(s.connectionState!=ConnectionState.done)return const Padding(padding:EdgeInsets.all(14),child:LinearProgressIndicator());if(s.data==null)return TextButton(onPressed:()=>setState(()=>imageFuture=fetch()),child:const Text('Tentar carregar imagem'));return GestureDetector(onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>MeowImageViewer(bytes:s.data!,name:name))),child:ClipRRect(borderRadius:const BorderRadius.vertical(top:Radius.circular(12)),child:ConstrainedBox(constraints:const BoxConstraints(maxHeight:250),child:Image.memory(s.data!,fit:BoxFit.contain,gaplessPlayback:true,errorBuilder:(c,e,st)=>const Text('Imagem indisponível')))));}),ListTile(dense:true,leading:Icon(isImage?Icons.image:Icons.insert_drive_file),title:Text(name,maxLines:1,overflow:TextOverflow.ellipsis),subtitle:Text(fileSizeLabel((widget.attachment['size'] as num?)?.toInt()??0)),trailing:IconButton(tooltip:'Salvar arquivo',onPressed:busy?null:save,icon:Icon(busy?Icons.hourglass_top:Icons.download))) ]));}
}
class FriendsPage extends StatelessWidget {
 final String uid;const FriendsPage({super.key,required this.uid});
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Amigos')),body:Column(children:[Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:8),child:TextField(decoration:const InputDecoration(labelText:'Buscar usuário',prefixIcon:Icon(Icons.search)),onSubmitted:(name)async{try{final n=cleanName(name.replaceFirst('@',''));final found=await db.collection('users').where('username',isEqualTo:n).limit(1).get();if(!c.mounted)return;if(found.docs.isEmpty){notice(c,'Usuário não encontrado');return;}openProfile(c,found.docs.first.id);}catch(e){if(c.mounted)notice(c,e);}})),Expanded(child:MutualFriendsList(uid:uid))]));
}
class MutualFriendsList extends StatefulWidget {
 final String uid;const MutualFriendsList({super.key,required this.uid});
 @override State<MutualFriendsList> createState()=>_MutualFriendsListState();
}
class _MutualFriendsListState extends State<MutualFriendsList>{
 StreamSubscription<QuerySnapshot<Map<String,dynamic>>>? following;final mutualSubs=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};final profileSubs=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};final profiles=<String,Map<String,dynamic>>{};Timer? timer;bool loaded=false;
 @override void initState(){super.initState();following=db.collection('users').doc(widget.uid).collection('following').snapshots().listen((s){if(!mounted)return;final ids=s.docs.map((d)=>d.id).toSet();for(final id in mutualSubs.keys.toList()){if(!ids.contains(id)){mutualSubs.remove(id)?.cancel();profileSubs.remove(id)?.cancel();profiles.remove(id);}}for(final id in ids){mutualSubs.putIfAbsent(id,()=>db.collection('users').doc(id).collection('following').doc(widget.uid).snapshots().listen((m){if(!mounted||!mutualSubs.containsKey(id))return;if(m.exists){profiles.putIfAbsent(id,()=>{});profileSubs.putIfAbsent(id,()=>db.collection('users').doc(id).snapshots().listen((u){if(mounted&&profileSubs.containsKey(id))setState(()=>profiles[id]=u.data()??{});}));}else{profileSubs.remove(id)?.cancel();profiles.remove(id);}setState((){});}));}setState(()=>loaded=true);},onError:(Object _){if(mounted)setState(()=>loaded=true);});timer=Timer.periodic(const Duration(seconds:15),(_){if(mounted)setState((){});});}
 @override void dispose(){following?.cancel();timer?.cancel();for(final s in mutualSubs.values){s.cancel();}for(final s in profileSubs.values){s.cancel();}super.dispose();}
 @override Widget build(BuildContext c){if(!loaded)return const Center(child:CircularProgressIndicator());if(profiles.isEmpty)return const Center(child:Text('Nenhum amigo ainda.'));final entries=profiles.entries.toList()..sort((a,b){final offA=currentPresence(a.value)=='offline';final offB=currentPresence(b.value)=='offline';if(offA!=offB)return offA?1:-1;return userLabel(a.value).compareTo(userLabel(b.value));});return ListView(children:[for(final e in entries)ListTile(leading:ProfileAvatar(uid:e.key),title:Text(userLabel(e.value)),subtitle:Text('@${e.value['username']??''}'),onTap:()=>openProfile(c,e.key))]);}
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
  const MeowTitle({super.key});
  @override Widget build(BuildContext context)=>FutureBuilder<PackageInfo>(
    future:PackageInfo.fromPlatform(),builder:(context,s)=>Row(mainAxisSize:MainAxisSize.min,children:[
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
   return StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:receiptRef(threadId,uid).snapshots(),builder:(context,read){
     final seen=read.data?.data()?['at'] as Timestamp?;
     return StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:collection.orderBy('createdAt',descending:true).limit(20).snapshots(),builder:(context,s){
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
 @override Widget build(BuildContext context)=>StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(widget.uid).snapshots(),builder:(c,s){
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
 @override Widget build(BuildContext c)=>StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(uid).snapshots(),builder:(c,u)=>StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:receiptRef(threadId,uid).snapshots(),builder:(c,r){
 final seen=r.data?.data()?['at'] as Timestamp?;final username=u.data?.data()?['username']?.toString()??'';
 return StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:collection.orderBy('createdAt',descending:true).limit(100).snapshots(),builder:(c,s){
 final unread=s.data?.docs.where((d){final t=d.data()['createdAt'];return d.data()['authorId']!=uid&&t is Timestamp&&(seen==null||t.compareTo(seen)>0);}).toList()??[];
 final count=unread.where((d){final m=d.data();final names=mentionNames(m['text']?.toString()??'');return m['replyAuthorId']==uid||names.contains(username)||(m['everyoneMention']==true&&names.contains('everyone'));}).length;
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
 final receipts=<String,Timestamp?>{};final items=<String,List<QueryDocumentSnapshot<Map<String,dynamic>>>>{};String username='';
 @override void initState(){super.initState();user=db.collection('users').doc(widget.uid).snapshots().listen((u){if(mounted)setState(()=>username=u.data()?['username']?.toString()??'');});channels=db.collection('servers').doc(widget.serverId).collection('channels').snapshots().listen((s){if(!mounted)return;final ids=s.docs.map((d)=>d.id).toSet();for(final id in messageSubs.keys.toList()){if(!ids.contains(id)){messageSubs.remove(id)?.cancel();receiptSubs.remove(id)?.cancel();items.remove(id);receipts.remove(id);}}for(final ch in s.docs){messageSubs.putIfAbsent(ch.id,()=>ch.reference.collection('messages').orderBy('createdAt',descending:true).limit(100).snapshots().listen((m){if(mounted)setState(()=>items[ch.id]=m.docs);}));receiptSubs.putIfAbsent(ch.id,()=>receiptRef('server:${widget.serverId}:${ch.id}',widget.uid).snapshots().listen((r){if(mounted)setState(()=>receipts[ch.id]=r.data()?['at'] as Timestamp?);}));}setState((){});},onError:(Object _){});}
 @override void dispose(){channels?.cancel();user?.cancel();for(final s in messageSubs.values){s.cancel();}for(final s in receiptSubs.values){s.cancel();}super.dispose();}
 @override Widget build(BuildContext c){var unread=false,count=0;for(final e in items.entries){final seen=receipts[e.key];for(final d in e.value){final m=d.data();final t=m['createdAt'];if(m['authorId']==widget.uid||t is! Timestamp||(seen!=null&&t.compareTo(seen)<=0))continue;unread=true;final names=mentionNames(m['text']?.toString()??'');if(m['replyAuthorId']==widget.uid||names.contains(username)||(m['everyoneMention']==true&&names.contains('everyone')))count++;}}return Row(mainAxisSize:MainAxisSize.min,children:[if(unread)const Icon(Icons.circle,color:Color(0xFF39F57A),size:10),if(count>0)Container(padding:const EdgeInsets.symmetric(horizontal:4,vertical:2),decoration:BoxDecoration(color:Colors.redAccent,borderRadius:BorderRadius.circular(12)),child:Text(count>99?'99+':'$count',style:const TextStyle(fontSize:10,color:Colors.white)))]);}
}
class DmPreview extends StatelessWidget{
 final String id,uid;const DmPreview({super.key,required this.id,required this.uid});
 @override Widget build(BuildContext c)=>StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('dms').doc(id).collection('messages').orderBy('createdAt',descending:true).limit(1).snapshots(),builder:(c,s){
  if(s.hasError)return const Text('Conversa',maxLines:1);
  if(s.data == null || s.data!.docs.isEmpty)return const Text('Inicie a conversa',maxLines:1);
  final d=s.data!.docs.first.data();final t=((d['text']?.toString()??'').isNotEmpty?d['text']:d['attachment'] is Map?'📎 Anexo':'Mensagem').toString();
  return Text('${d['authorId']==uid?'Você: ':''}$t',maxLines:1,overflow:TextOverflow.ellipsis);
 });
}
// Consultas restritas ao destinatario: nao varrem solicitacoes de terceiros.
Stream<QuerySnapshot<Map<String, dynamic>>> myDmRequests(String uid) =>
    db.collection('dmRequests').where('to', isEqualTo: uid).where('status', isEqualTo: 'pending').snapshots();

class DmRequestsDot extends StatelessWidget {
  final String uid;
  const DmRequestsDot({super.key, required this.uid});
  @override
  Widget build(BuildContext context) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
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
    body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
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
                        Navigator.push(context, MaterialPageRoute(builder: (_) =>
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
  Widget build(BuildContext context) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
    stream: db.collection('users').doc(uid).collection('following').doc(other).snapshots(),
    builder: (context, mine) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('users').doc(other).collection('following').doc(uid).snapshots(),
      builder: (context, theirs) {
        if (mine.hasError || theirs.hasError) return const Center(child: Text('Nao foi possivel verificar a amizade.'));
        if (!mine.hasData || !theirs.hasData) return const Center(child: CircularProgressIndicator());
        if (mine.data!.exists && theirs.data!.exists) {
          return MessageThread(collection: db.collection('dms').doc(id).collection('messages'), uid: uid, threadId: 'dm:$id',initialMessageId:initialMessageId);
        }
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: db.collection('dmRequests').doc(id).snapshots(),
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
Future<void> confirmServerDelete(BuildContext context,String id)async{
 final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('Excluir servidor?'),content:const Text('Esta ação é permanente e apagará canais e mensagens quando o backend concluir a exclusão.'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancelar')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Excluir'))]));
 if(ok!=true)return;
 try{await db.collection('serverDeletionRequests').doc(id).set({'ownerId':myUid,'requestedAt':FieldValue.serverTimestamp()});if(context.mounted)notice(context,'Exclusão solicitada. Aguardando processamento do servidor.');}catch(e){if(context.mounted)notice(context,e);}
}

class ProfileBackground extends StatelessWidget {
 final String uid; const ProfileBackground({super.key,required this.uid});
 @override Widget build(BuildContext c)=>FutureBuilder<Uint8List?>(future:PrivateMediaCache.get(mediaUrl('profile',uid,'background')),builder:(c,s)=>s.data==null?const SizedBox.shrink():Stack(fit:StackFit.expand,children:[Image.memory(s.data!,fit:BoxFit.cover,errorBuilder:(c,e,st)=>const SizedBox.shrink()),const ColoredBox(color:Color(0x99000000))]));
}
class TypingLabel extends StatefulWidget {
 final CollectionReference<Map<String,dynamic>> collection;final String uid;
 const TypingLabel({super.key,required this.collection,required this.uid});
 @override State<TypingLabel> createState()=>_TypingLabelState();
}
class _TypingLabelState extends State<TypingLabel>{
 Timer? timer;late Stream<QuerySnapshot<Map<String,dynamic>>> stream;int frame=0;
 final names=<String,String>{};final loading=<String>{};
 @override void initState(){super.initState();stream=widget.collection.snapshots();timer=Timer.periodic(const Duration(milliseconds:400),(_){if(mounted)setState(()=>frame=(frame+1)%3);});}
 @override void dispose(){timer?.cancel();super.dispose();}
 Future<void> load(String id)async{if(names.containsKey(id)||!loading.add(id))return;try{final d=(await db.collection('users').doc(id).get()).data()??{};if(mounted)setState(()=>names[id]=userLabel(d));}catch(_){}finally{loading.remove(id);}}
 @override Widget build(BuildContext c)=>StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:stream,builder:(c,s){final ids=s.data?.docs.where((d){final t=d.data()['at'];return d.id!=widget.uid&&t is Timestamp&&DateTime.now().difference(t.toDate())<const Duration(seconds:4);}).map((d)=>d.id).toList()??[];if(ids.length<=3){for(final id in ids){if(!names.containsKey(id))unawaited(load(id));}}final n=ids.map((id)=>names[id]??'Alguém').toList();final text=switch(n.length){0=>'',1=>'${n[0]} está digitando',2=>'${n[0]} e ${n[1]} estão digitando',3=>'${n[0]}, ${n[1]} e ${n[2]} estão digitando',_=>'Muitas pessoas estão digitando'};return SizedBox(height:24,child:ids.isEmpty?null:Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Row(children:[Flexible(child:Text(text,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:12))),const SizedBox(width:3),for(var i=0;i<3;i++)AnimatedOpacity(opacity:frame==i?1:.35,duration:const Duration(milliseconds:200),child:const Text('•'))])));});
}
const meowEmojis=['😀','😂','😍','😭','😎','🥰','😡','🤔','😴','😺','❤️','💜','👍','👎','🔥','🎉','✨','💀','👀','🙏','🐱','🐶','🌸','🍕','🎮','💯'];
Uri expressionUrl(Map<String,dynamic> d,{String? message,String? reaction})=>Uri.https(imageHost,'/functions/v1/meow-expressoes',{'server':d['serverId'].toString(),'id':d['id'].toString(),'kind':d['kind'].toString(),if(message!=null)'message':message,if(reaction!=null)'reaction':reaction});
class ExpressionImage extends StatelessWidget{
 final Map<String,dynamic> data;final String? message,reaction;final double? size;
 const ExpressionImage({super.key,required this.data,this.message,this.reaction,this.size});
 @override Widget build(BuildContext c){final n=size??(data['kind']=='sticker'?144.0:48.0);return SizedBox(width:n,height:n,child:FutureBuilder<Uint8List?>(future:PrivateMediaCache.get(expressionUrl(data,message:message,reaction:reaction)),builder:(c,s)=>s.data==null?const Icon(Icons.image_outlined):Image.memory(s.data!,fit:BoxFit.contain,errorBuilder:(c,e,st)=>const Icon(Icons.broken_image))));}
}
Future<Object?> pickExpression(BuildContext context,{bool reactionOnly=false})=>showModalBottomSheet<Object>(context:context,isScrollControlled:true,builder:(c)=>SafeArea(child:SizedBox(height:420,child:DefaultTabController(length:reactionOnly?2:3,child:Column(children:[TabBar(tabs:[const Tab(text:'Emojis'),const Tab(text:'Personalizados'),if(!reactionOnly)const Tab(text:'Figurinhas')]),Expanded(child:TabBarView(children:[GridView.count(crossAxisCount:6,children:[for(final e in meowEmojis)TextButton(onPressed:()=>Navigator.pop(c,e),child:Text(e,style:const TextStyle(fontSize:26)))]),for(final kind in ['emoji',if(!reactionOnly)'sticker'])StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('servers').where('members',arrayContains:myUid).snapshots(),builder:(c,s)=>ListView(children:[for(final server in s.data?.docs??[])Column(crossAxisAlignment:CrossAxisAlignment.start,children:[ListTile(title:Text(server.data()['name']?.toString()??'Servidor')),StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:server.reference.collection('expressions').where('active',isEqualTo:true).snapshots(),builder:(c,x)=>Wrap(children:[for(final item in x.data?.docs??[])if(item.data()['kind']==kind)InkWell(onTap:()=>Navigator.pop(c,<String,dynamic>{'serverId':server.id,'id':item.id,'kind':kind}),child:Padding(padding:const EdgeInsets.all(6),child:ExpressionImage(data:item.data(),size:kind=='emoji'?48:88)))]))])]))]))])))));
class ExpressionSettings extends StatelessWidget{
 final String server;const ExpressionSettings({super.key,required this.server});
 CollectionReference<Map<String,dynamic>> get catalog=>db.collection('servers').doc(server).collection('expressions');
 Future<void> add(BuildContext c,String kind)async{try{final name=await showTextPrompt(c,'Nome','');if(name==null||name.length<2||name.length>32||!c.mounted)return;final f=await files.openFile(acceptedTypeGroups:const [files.XTypeGroup(label:'Imagens',extensions:['png','jpg','jpeg','gif','webp'])]);if(f==null)return;if(await f.length()>5000000)throw Exception('Limite de 5 MB.');final uri=Uri.https(imageHost,'/functions/v1/meow-expressoes',{'server':server,'kind':kind,'name':name});final response=await http.post(uri,headers:await authHeaders(),body:await f.readAsBytes()).timeout(const Duration(seconds:120));if(response.statusCode!=201)throw Exception(response.body);final d=Map<String,dynamic>.from(jsonDecode(response.body) as Map);await catalog.doc(d['id'].toString()).set({...d,'active':true,'createdAt':FieldValue.serverTimestamp()});if(c.mounted)notice(c,'Imagem adicionada.');}catch(e){if(c.mounted)notice(c,e);}}
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Emojis e figurinhas')),body:Column(children:[Wrap(children:[TextButton(onPressed:()=>add(c,'emoji'),child:const Text('Adicionar emoji')),TextButton(onPressed:()=>add(c,'sticker'),child:const Text('Adicionar figurinha'))]),Expanded(child:StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:catalog.where('active',isEqualTo:true).snapshots(),builder:(c,s)=>ListView(children:[for(final d in s.data?.docs??[])ListTile(leading:ExpressionImage(data:d.data(),size:48),title:Text(d.data()['name'].toString()),trailing:PopupMenuButton<String>(onSelected:(v)async{try{if(v=='delete'){await d.reference.update({'active':false});}else{final name=await showTextPrompt(c,'Renomear',d.data()['name'].toString());if(name!=null&&name.length>=2&&name.length<=32)await d.reference.update({'name':name});}}catch(e){if(c.mounted)notice(c,e);}},itemBuilder:(_)=>const [PopupMenuItem(value:'rename',child:Text('Renomear')),PopupMenuItem(value:'delete',child:Text('Remover'))]))])))]));
}
String reactionKey(Map<String,dynamic> d){final e=d['expression'];return e is Map?'custom:${e['serverId']}:${e['id']}':'emoji:${d['emoji']}';}
Future<void> addReaction(BuildContext c,DocumentReference<Map<String,dynamic>> ref,String uid)async{final selected=await pickExpression(c,reactionOnly:true);if(selected==null||!c.mounted)return;try{final data=<String,dynamic>{'at':FieldValue.serverTimestamp(),if(selected is String)'emoji':selected,if(selected is Map<String,dynamic>)'expression':selected};final own=ref.collection('reactions').doc(uid);final old=(await own.get()).data();if(old!=null&&reactionKey(old)==reactionKey(data)){await own.delete();}else{await own.set(data);}}catch(e){if(c.mounted)notice(c,e);}}
class ReactionBar extends StatelessWidget{
 final DocumentReference<Map<String,dynamic>> ref;final String uid;const ReactionBar({super.key,required this.ref,required this.uid});
 @override Widget build(BuildContext c)=>StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:ref.collection('reactions').snapshots(),builder:(c,s){final groups=<String,List<QueryDocumentSnapshot<Map<String,dynamic>>>>{};for(final d in s.data?.docs??[]){groups.putIfAbsent(reactionKey(d.data()),()=>[]).add(d);}if(groups.isEmpty)return const SizedBox.shrink();return Padding(padding:const EdgeInsets.only(top:4),child:Wrap(spacing:5,runSpacing:4,children:[for(final g in groups.values)Builder(builder:(c){final data=g.first.data();final mine=g.any((d)=>d.id==uid);return InkWell(borderRadius:BorderRadius.circular(7),onTap:()async{try{final own=ref.collection('reactions').doc(uid);if(mine){await own.delete();}else{await own.set({'at':FieldValue.serverTimestamp(),if(data['expression'] is Map)'expression':data['expression'] else 'emoji':data['emoji']});}}catch(e){if(c.mounted)notice(c,e);}},child:Container(padding:const EdgeInsets.symmetric(horizontal:7,vertical:3),decoration:BoxDecoration(color:mine?purple.withOpacity(.22):panel,borderRadius:BorderRadius.circular(7),border:Border.all(color:mine?purple:Colors.white12)),child:Row(mainAxisSize:MainAxisSize.min,children:[if(data['expression'] is Map)ExpressionImage(data:Map<String,dynamic>.from(data['expression']),message:ref.path,reaction:g.first.id,size:20)else Text(data['emoji']?.toString()??'',style:const TextStyle(fontSize:20)),const SizedBox(width:4),Text('${g.length}',style:const TextStyle(fontSize:12))])));})]));});
}

bool validMessagePath(String p)=>RegExp(r'^(dms/[\w-]+|servers/[\w-]+/channels/[\w-]+)/messages/[\w-]+$').hasMatch(p);
String threadFromPath(String p){final x=p.split('/');return x.first=='dms'?'dm:${x[1]}':'server:${x[1]}:${x[3]}';}
Set<String> mentionNames(String text)=>RegExp(r'(?:^|\s)@([a-zA-Z0-9_]+)').allMatches(text).map((m)=>m.group(1)!.toLowerCase()).toSet();
String fileSizeLabel(int n)=>n>=1048576?'${(n/1048576).toStringAsFixed(1)} MiB':n>=1024?'${(n/1024).toStringAsFixed(1)} KiB':'$n B';
class MeowNotificationBanner extends StatelessWidget {
 final String sender,title,subtitle,preview;final VoidCallback onDismiss,onTap;
 const MeowNotificationBanner({super.key,required this.sender,required this.title,required this.subtitle,required this.preview,required this.onDismiss,required this.onTap});
 @override Widget build(BuildContext c)=>TweenAnimationBuilder<double>(tween:Tween(begin:0,end:1),duration:const Duration(milliseconds:220),builder:(c,v,child)=>Transform.translate(offset:Offset(0,-25*(1-v)),child:Opacity(opacity:v,child:child)),child:Dismissible(key:ValueKey('$sender$preview'),direction:DismissDirection.horizontal,onDismissed:(_)=>onDismiss(),child:Material(elevation:10,color:panel,borderRadius:BorderRadius.circular(16),child:InkWell(onTap:onTap,borderRadius:BorderRadius.circular(16),child:Padding(padding:const EdgeInsets.all(12),child:Row(children:[PrivateImage(scope:'profile',id:sender,slot:'avatar',size:44),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisSize:MainAxisSize.min,children:[Text(title,style:const TextStyle(fontWeight:FontWeight.bold,color:Colors.white)),Text(subtitle,style:const TextStyle(fontSize:12,color:Colors.white70)),Text(preview,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white))])),IconButton(onPressed:onDismiss,icon:const Icon(Icons.close,color:Colors.white70))]))))));
}
class MuteButton extends StatelessWidget {
 final String thread;const MuteButton({super.key,required this.thread});
 @override Widget build(BuildContext c){final ref=db.collection('users').doc(myUid).collection('mutedThreads').doc(base64Url.encode(utf8.encode(thread)).replaceAll('=',''));return StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:ref.snapshots(),builder:(c,s){final muted=s.data?.exists==true;return IconButton(tooltip:muted?'Ativar notificações':'Silenciar conversa',icon:Icon(muted?Icons.notifications_off:Icons.notifications_none),onPressed:()async{try{if(muted){await ref.delete();}else{await ref.set({'thread':thread});}}catch(e){if(c.mounted)notice(c,e);}});});}
}
class UnreadDmRail extends StatelessWidget {
 final String uid;const UnreadDmRail({super.key,required this.uid});
 @override Widget build(BuildContext c)=>StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('dms').where('members',arrayContains:uid).snapshots(),builder:(c,s)=>Column(children:[for(final d in s.data?.docs??[])UnreadDmRailItem(key:ValueKey(d.id),uid:uid,dm:d),if(s.data?.docs.isNotEmpty==true)const Divider(indent:20,endIndent:20,height:10)]));
}
class UnreadDmRailItem extends StatelessWidget {
 final String uid;final QueryDocumentSnapshot<Map<String,dynamic>> dm;const UnreadDmRailItem({super.key,required this.uid,required this.dm});
 @override Widget build(BuildContext c){final others=List<String>.from(dm.data()['members']??[]).where((x)=>x!=uid);if(others.isEmpty)return const SizedBox.shrink();final other=others.first;return StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:receiptRef('dm:${dm.id}',uid).snapshots(),builder:(c,r)=>StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:dm.reference.collection('messages').orderBy('createdAt',descending:true).limit(30).snapshots(),builder:(c,s){final seen=r.data?.data()?['at'];final unread=s.data?.docs.any((d){final t=d.data()['createdAt'];return d.data()['authorId']!=uid&&t is Timestamp&&(seen is! Timestamp||t.compareTo(seen)>0);})??false;if(!unread)return const SizedBox.shrink();return Padding(padding:const EdgeInsets.symmetric(vertical:4),child:IconButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>DmChatPage(id:dm.id,other:other,uid:uid))),icon:Stack(clipBehavior:Clip.none,children:[PrivateImage(scope:'profile',id:other,slot:'avatar',size:48),const Positioned(bottom:0,right:0,child:Icon(Icons.circle,color:Color(0xFF39F57A),size:13))]))); }));}
}
class ServerMembers extends StatefulWidget {
 final String server;const ServerMembers({super.key,required this.server});
 @override State<ServerMembers> createState()=>_ServerMembersState();
}
class _ServerMembersState extends State<ServerMembers>{
 final users=<String,Map<String,dynamic>>{};final subs=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? serverSub;Timer? timer;
 @override void initState(){super.initState();serverSub=db.collection('servers').doc(widget.server).snapshots().listen((s){if(!mounted)return;final ids=List<String>.from(s.data()?['members']??[]).toSet();for(final id in subs.keys.toList()){if(!ids.contains(id)){subs.remove(id)?.cancel();users.remove(id);}}for(final id in ids){users.putIfAbsent(id,()=>{});subs.putIfAbsent(id,()=>db.collection('users').doc(id).snapshots().listen((u){if(mounted)setState(()=>users[id]=u.data()??{});}));}setState((){});});timer=Timer.periodic(const Duration(seconds:15),(_){if(mounted)setState((){});});}
 @override void dispose(){timer?.cancel();serverSub?.cancel();for(final s in subs.values){s.cancel();}super.dispose();}
 @override Widget build(BuildContext c){final online=users.entries.where((e)=>currentPresence(e.value)!='offline').toList()..sort((a,b)=>userLabel(a.value).compareTo(userLabel(b.value)));final offline=users.entries.where((e)=>currentPresence(e.value)=='offline').toList()..sort((a,b)=>userLabel(a.value).compareTo(userLabel(b.value)));return SafeArea(child:Column(children:[ListTile(title:const Text('Membros',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),trailing:IconButton(onPressed:()=>Navigator.pop(c),icon:const Icon(Icons.close))),Expanded(child:ListView(children:[for(final group in [online,offline])...[Padding(padding:const EdgeInsets.all(12),child:Text('${identical(group,online)?'ONLINE':'OFFLINE'} — ${group.length}',style:const TextStyle(fontSize:12,color:Colors.white70))),for(final e in group)ListTile(leading:ProfileAvatar(uid:e.key),title:Text(userLabel(e.value)),subtitle:Text('@${e.value['username']??''}'),onTap:()=>openProfile(c,e.key))]]))]));}
}
class FriendsPreview extends StatelessWidget {
 final String uid;final Color background,ink;const FriendsPreview({super.key,required this.uid,required this.background,required this.ink});
 Future<List<String>> mutual(List<QueryDocumentSnapshot<Map<String,dynamic>>> docs)async{final checks=await Future.wait(docs.map((d)=>db.collection('users').doc(d.id).collection('following').doc(uid).get()));return checks.where((d)=>d.exists).map((d)=>d.reference.parent.parent!.id).toList();}
 @override Widget build(BuildContext c)=>StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(uid).collection('following').snapshots(),builder:(c,s)=>FutureBuilder<List<String>>(future:mutual(s.data?.docs??[]),builder:(c,f){final ids=f.data??[];final preview=ids.take(6).toList();return InkWell(borderRadius:BorderRadius.circular(14),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>uid==myUid?FriendsPage(uid:uid):RelationshipListPage(uid:uid,kind:'friends'))),child:Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:background,borderRadius:BorderRadius.circular(14)),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Amigos (${ids.length})',style:TextStyle(fontWeight:FontWeight.bold,color:ink)),if(preview.isNotEmpty)...[const SizedBox(height:8),SizedBox(height:35,width:35.0+(preview.length-1)*25.0,child:Stack(children:[for(var i=0;i<preview.length;i++)Positioned(left:i*25.0,child:PrivateImage(scope:'profile',id:preview[i],slot:'avatar',size:35))]))]])),Icon(Icons.chevron_right,color:ink)])));}));
}
class MeowTabs extends StatefulWidget {
 final int index;final List<Widget> children;const MeowTabs({super.key,required this.index,required this.children});
 @override State<MeowTabs> createState()=>_MeowTabsState();
}
class _MeowTabsState extends State<MeowTabs> with SingleTickerProviderStateMixin {
 late AnimationController controller;int direction=1;
 @override void initState(){super.initState();controller=AnimationController(vsync:this,duration:const Duration(milliseconds:200),value:1);}
 @override void didUpdateWidget(covariant MeowTabs old){super.didUpdateWidget(old);if(old.index!=widget.index){direction=widget.index>old.index?1:-1;controller.forward(from:0);}}
 @override void dispose(){controller.dispose();super.dispose();}
 @override Widget build(BuildContext c)=>AnimatedBuilder(animation:controller,builder:(c,child){final v=Curves.easeOutCubic.transform(controller.value);return ClipRect(child:Transform.translate(offset:Offset(direction*(1-v)*22,0),child:Opacity(opacity:.75+.25*v,child:child)));},child:IndexedStack(index:widget.index,children:[for(var i=0;i<widget.children.length;i++)TickerMode(enabled:i==widget.index,child:widget.children[i])]));
}
class ChannelSlide extends StatefulWidget {
 final bool open;final ValueChanged<bool> onChange;final Widget list,chat;const ChannelSlide({super.key,required this.open,required this.onChange,required this.list,required this.chat});
 @override State<ChannelSlide> createState()=>_ChannelSlideState();
}
class _ChannelSlideState extends State<ChannelSlide> with SingleTickerProviderStateMixin {
 late AnimationController controller;
 @override void initState(){super.initState();controller=AnimationController(vsync:this,duration:const Duration(milliseconds:210),value:widget.open?1:0);}
 @override void didUpdateWidget(covariant ChannelSlide old){super.didUpdateWidget(old);if(old.open!=widget.open)controller.animateTo(widget.open?1:0,curve:Curves.easeOutCubic);}
 @override void dispose(){controller.dispose();super.dispose();}
 void end(DragEndDetails d){final v=d.primaryVelocity??0;final open=v>350?true:v< -350?false:controller.value>.5;widget.onChange(open);controller.animateTo(open?1:0,curve:Curves.easeOutCubic);}
 @override Widget build(BuildContext c)=>LayoutBuilder(builder:(c,b)=>AnimatedBuilder(animation:controller,builder:(c,_){final x=controller.value*b.maxWidth;return ClipRect(child:Stack(children:[Positioned.fill(child:IgnorePointer(ignoring:!widget.open,child:GestureDetector(onHorizontalDragStart:(_)=>controller.stop(),onHorizontalDragUpdate:(d)=>controller.value=(controller.value+(d.primaryDelta??0)/b.maxWidth).clamp(0.0,1.0).toDouble(),onHorizontalDragEnd:end,onHorizontalDragCancel:()=>controller.animateTo(widget.open?1:0),child:widget.list))),Positioned(left:x,width:b.maxWidth,top:0,bottom:0,child:Material(color:bg,child:IgnorePointer(ignoring:widget.open,child:widget.chat))),if(!widget.open)Positioned(left:x,top:48,bottom:0,width:18,child:GestureDetector(behavior:HitTestBehavior.translucent,onHorizontalDragStart:(_)=>controller.stop(),onHorizontalDragUpdate:(d)=>controller.value=(controller.value+(d.primaryDelta??0)/b.maxWidth).clamp(0.0,1.0).toDouble(),onHorizontalDragEnd:end,onHorizontalDragCancel:()=>controller.animateTo(0))) ]));}));
}
class ReplySwipe extends StatefulWidget {
 final Widget child;final VoidCallback onReply;const ReplySwipe({super.key,required this.child,required this.onReply});
 @override State<ReplySwipe> createState()=>_ReplySwipeState();
}
class _ReplySwipeState extends State<ReplySwipe>{double x=0;bool dragging=false,haptic=false;@override Widget build(BuildContext c)=>GestureDetector(onHorizontalDragStart:(_){setState(()=>dragging=true);},onHorizontalDragUpdate:(d){setState(()=>x=(x+(d.primaryDelta??0)*.65).clamp(0.0,90.0).toDouble());if(x>=55&&!haptic){haptic=true;HapticFeedback.selectionClick();}},onHorizontalDragEnd:(_){if(x>=55)widget.onReply();setState((){x=0;dragging=false;haptic=false;});},onHorizontalDragCancel:()=>setState((){x=0;dragging=false;haptic=false;}),child:Stack(alignment:Alignment.centerLeft,children:[if(x>5)Padding(padding:const EdgeInsets.only(left:8),child:Icon(Icons.reply,color:x>=55?purple:Colors.white54)),AnimatedContainer(duration:dragging?Duration.zero:const Duration(milliseconds:160),transform:Matrix4.translationValues(x,0,0),child:widget.child)]));}
class MeowMessageText extends StatelessWidget {
 final String text;final Map<String,Map<String,dynamic>> people;const MeowMessageText({super.key,required this.text,required this.people});
 bool emoji(String c)=>RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}]',unicode:true).hasMatch(c);
 @override Widget build(BuildContext c){final graphemes=text.characters.where((g)=>g.trim().isNotEmpty).toList();final only=graphemes.isNotEmpty&&graphemes.length<=5&&graphemes.every(emoji);if(only)return Text(text,style:const TextStyle(fontSize:48));final spans=<InlineSpan>[];final matcher=RegExp(r'(?<![a-zA-Z0-9_])@([a-zA-Z0-9_]+)');void plain(String t){for(final g in t.characters){spans.add(TextSpan(text:g,style:emoji(g)?const TextStyle(fontSize:26):null));}}var last=0;for(final m in matcher.allMatches(text)){plain(text.substring(last,m.start));final name=m.group(1)!.toLowerCase();final found=people.entries.where((e)=>e.value['username']==name);if(found.isNotEmpty){final id=found.first.key;spans.add(WidgetSpan(alignment:PlaceholderAlignment.middle,child:InkWell(onTap:()=>openProfile(c,id),child:Container(padding:const EdgeInsets.symmetric(horizontal:2),decoration:BoxDecoration(color:purple.withOpacity(.18),borderRadius:BorderRadius.circular(4)),child:Text(m.group(0)!,style:const TextStyle(color:Color(0xFFC4B5FD),fontWeight:FontWeight.w600))))));}else{spans.add(TextSpan(text:m.group(0),style:name=='everyone'?const TextStyle(color:Color(0xFFC4B5FD)):null));}last=m.end;}plain(text.substring(last));return Text.rich(TextSpan(children:spans));}
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
