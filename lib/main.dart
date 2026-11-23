import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_selector/file_selector.dart' as files;
import 'package:flutter/cupertino.dart';
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
    @override Widget build(BuildContext context) => MaterialApp(debugShowCheckedModeBanner:false, title:'Meow',
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
      PrivateMediaCache.invalidate(widget.url);
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
      final limit=widget.slot=='banner'?bannerLimit:avatarLimit;
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
      final headers = await authHeaders();
      headers['Content-Type'] = imageMime[extension] ?? 'application/octet-stream';
      final r=await http.put(mediaUrl(widget.scope, widget.id, widget.slot), headers:headers,
      body:await f.readAsBytes()
).timeout(const Duration(seconds:120));
      if(r.statusCode!=200)throw Exception('Upload falhou: ${r.statusCode} ${r.body}');
      if(widget.scope=='profile'&&widget.slot=='banner')await db.collection('users').doc(widget.id).update({'bannerHidden':false});
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

class PresenceDot extends StatelessWidget {
  final String uid;
  const PresenceDot({
    super.key,
    required this.uid
}
);
  @override Widget build(BuildContext c)=>StreamBuilder<DocumentSnapshot<Map<String,
  dynamic>>>(stream:db.collection('users').doc(uid).snapshots(), builder:(c, s){
    final d=s.data?.data();
    final p=d?['presence']=='invisible'?'offline':(d?['presence']?.toString()??'offline');
      return Container(width:11, height:11, decoration:BoxDecoration(color:presenceColor(p), shape:BoxShape.circle,
    border:Border.all(color:bg, width:2)
));
}
);
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
void openProfile(BuildContext context, String uid){
  if(uid.isEmpty)return;
    showModalBottomSheet<void>(context:context, isScrollControlled:true, useSafeArea:true, backgroundColor:panel,
      builder:(c)=>DraggableScrollableSheet(expand:false, initialChildSize:.82, maxChildSize:.96, builder:(c,
    scroll
)=>ProfilePage(uid:uid, expanded:true, scrollController:scroll))
);
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
  final String uid;
  final bool expanded;
  final ScrollController? scrollController;
  const ProfilePage({
    super.key,
    required this.uid,
    this.expanded=false,
    this.scrollController
}
);
  @override Widget build(BuildContext c)=>StreamBuilder<DocumentSnapshot<Map<String,
  dynamic>>>(stream:db.collection('users').doc(uid).snapshots(), builder:(c, s){
    if(s.hasError)return const Center(child:Text('Perfil indisponível.'));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    final d=s.data?.data()??{
}
;
    final username=d['username']?.toString()??'meow';
    final own=uid==FirebaseAuth.instance.currentUser?.uid;
    final p=d['presence']?.toString()??'offline';
      return Container(decoration:d['bannerHidden']==true?BoxDecoration(gradient:profileGradient(d)):null,child:ListView(controller:scrollController, children:[Stack(clipBehavior:Clip.none, children:[ProfileBanner(uid:uid,data:d), Positioned(left:18, bottom:-44, child:Container(padding:const EdgeInsets.all(4), decoration:BoxDecoration(color:d['bannerHidden']==true?Colors.transparent:panel,
    shape:BoxShape.circle
), child:PrivateImage(scope:'profile', id:uid, slot:'avatar', size:88)))]), const SizedBox(height:55),
        Container(decoration:d['bannerHidden']==true?null:BoxDecoration(gradient:profileGradient(d)),padding:const EdgeInsets.all(18), child:Column(crossAxisAlignment:CrossAxisAlignment.start,
          children:[Text(d['displayName']?.toString()??username, style:const TextStyle(fontSize:24, fontWeight:FontWeight.bold)),
          Text('@$username', style:const TextStyle(color:Colors.white60)), if((d['pronouns']?.toString()??'').isNotEmpty)Text(d['pronouns'].toString(),style:const TextStyle(color:Colors.white70)), const SizedBox(height:12), RelationshipCounters(uid:uid), if(!own)FollowButton(target:uid), 
            const SizedBox(height:8), Row(children:[Icon(Icons.circle, size:12, color:presenceColor(own?p:(p=='invisible'?'offline':p))),
          const SizedBox(width:6), Text(own?(presenceLabels[p]??'Offline'):(p=='invisible'?'Offline':(presenceLabels[p]??'Offline')))
]), if((d['customStatus']?.toString()??'').isNotEmpty)Padding(padding:const EdgeInsets.only(top:8),
          child:Text(d['customStatus'].toString())
), if((d['bio']?.toString()??'').isNotEmpty)...[const SizedBox(height:18), const Text('SOBRE MIM',
          style:TextStyle(color:Colors.white60, fontSize:12)
), const SizedBox(height:6), Text(d['bio'].toString())], const SizedBox(height:20), if(own)SizedBox(width:double.infinity,
              child:FilledButton.icon(onPressed:()=>Navigator.push(c, MaterialPageRoute(builder:(_)=>EditProfilePage(uid:uid))),
            icon:const Icon(Icons.edit), label:const Text('Editar perfil e status')
)
), if(!own)SizedBox(width:double.infinity, child:FilledButton.icon(onPressed:()async{
            final navigator = Navigator.of(c);
            final safeContext = navigator.context;
            if (expanded) navigator.pop();
            await openDm(safeContext, uid);
}
, icon:const Icon(Icons.message), label:const Text('Enviar mensagem'))), if(own&&!expanded)TextButton.icon(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const AppSettingsPage())),icon:const Icon(Icons.settings),label:const Text('Configurações do aplicativo')), 
]
))
]));
}
);
}


class AppSettingsPage extends StatelessWidget {
  const AppSettingsPage({super.key});
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Configurações')),
    body:ListView(children:[
      ListTile(leading:const Icon(Icons.person),title:const Text('Conta'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Conta')),body:ListView(children:[
        ListTile(title:const Text('Editar perfil'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>EditProfilePage(uid:myUid)))),
        ListTile(title:const Text('Alterar senha'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const ChangePasswordPage()))), ListTile(title:const Text('Sair da conta'),onTap:(){PrivateMediaCache.clear();FirebaseAuth.instance.signOut();})]))))),
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
  bool enabled=true;
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Notificações')),
    body:SwitchListTile(title:const Text('Notificações neste dispositivo'),value:enabled,onChanged:(v)async{
      try{if(v){await FirebaseMessaging.instance.requestPermission();final t=await FirebaseMessaging.instance.getToken();if(t!=null)await db.collection('users').doc(myUid).collection('devices').doc(t).set({'token':t,'updatedAt':FieldValue.serverTimestamp()});}
      else {final t=await FirebaseMessaging.instance.getToken();if(t!=null)await db.collection('users').doc(myUid).collection('devices').doc(t).delete();}
      if(mounted)setState(()=>enabled=v);
      }catch(e){if(mounted)notice(context,e);}
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
          return ListView(children:[Stack(clipBehavior:Clip.none, children:[ProfileBanner(uid:widget.uid,data:d), Positioned(right:10,top:10,child:Row(mainAxisSize:MainAxisSize.min,children:[ChangeImage('profile',widget.uid,'banner','Trocar banner',iconOnly:true),IconButton.filledTonal(tooltip:'Remover banner',onPressed:()async{await db.collection('users').doc(widget.uid).update({'bannerHidden':true});},icon:const Icon(Icons.hide_image))])), Positioned(left:18, bottom:-45, child:Stack(alignment:Alignment.bottomRight, children:[PrivateImage(scope:'profile',
        id:widget.uid, slot:'avatar', size:90
), ChangeImage('profile', widget.uid, 'avatar', 'Trocar foto', iconOnly:true)]))]), const SizedBox(height:64),
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
), const SizedBox(height:12), ProfileThemeEditor(uid:widget.uid),const SizedBox(height:20), SizedBox(width:double.infinity, child:FilledButton(onPressed:busy?null:save,
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
                const SizedBox(height:18), if(owner) OutlinedButton.icon(icon:const Icon(Icons.edit),label:const Text('Renomear servidor'),onPressed:()async{final v=await showTextPrompt(c,'Nome do servidor',d['name']?.toString()??'');if(v!=null&&v.isNotEmpty)await db.collection('servers').doc(id).update({'name':v});}), const SizedBox(height:12), if(owner) ListTile(title:const Text('Organizar categorias e canais'),trailing:const Icon(Icons.chevron_right),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ServerOrganizationPage(id:id)))), if(owner) ChangeImage('server', id, 'avatar', 'Trocar ícone (8 MiB)'),if(owner) ChangeImage('server',id,'banner','Trocar banner (15 MiB)'),if(owner) OutlinedButton.icon(onPressed:()=>confirmServerDelete(c,id),icon:const Icon(Icons.delete),label:const Text('Excluir servidor')),if(!owner)OutlinedButton.icon(onPressed:()=>confirmLeaveServer(c,id),icon:const Icon(Icons.logout),label:const Text('Sair do servidor'))
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
      final fcm=FirebaseMessaging.instance;
      await fcm.requestPermission(alert:true, badge:true, sound:true);
      final token=await fcm.getToken();
      if(token!=null)await db.collection('users').doc(myUid).collection('devices').doc(token).set({
        'token':token,
        'updatedAt':FieldValue.serverTimestamp()
}
);
      tokenSub=fcm.onTokenRefresh.listen((token)async{
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
    tokenSub?.cancel();
    presenceTimer?.cancel();
    super.dispose();
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
    Widget rail()=>SizedBox(width:68, child:ColoredBox(color:const Color(0xFF0B0C11), child:Column(children:[IconButton(onPressed:createServer,
  icon:const Icon(Icons.add_circle, color:purple)
), IconButton(onPressed:joinInvite, icon:const Icon(Icons.group_add)), Expanded(child:StreamBuilder<QuerySnapshot<Map<String,
      dynamic>>>(stream:db.collection('servers').where('members', arrayContains:myUid).snapshots(), builder:(c,
    s
)=>ListView(children:[for(final d in s.data?.docs??[])Padding(padding:const EdgeInsets.symmetric(vertical:5),
      child:IconButton(tooltip:d.data()['name']?.toString()??'Servidor', onPressed:()=>setState((){
        serverId=d.id;
        channelId=null;
        showingChannels=true;
}
), icon:Stack(clipBehavior:Clip.none,children:[PrivateImage(scope:'server', id:d.id, slot:'avatar', size:36),Positioned(right:-2,bottom:-2,child:ServerUnreadDot(serverId:d.id,uid:myUid))]))
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
        return GestureDetector(onHorizontalDragEnd:(d){
          final v=d.primaryVelocity??0;
          if(v>250&&!showingChannels)setState(()=>showingChannels=true);
          if(v< -250&&showingChannels&&active!=null)setState(()=>showingChannels=false);
}
, child:AnimatedSwitcher(duration:const Duration(milliseconds:240),switchInCurve:Curves.easeOutCubic,switchOutCurve:Curves.easeInCubic,transitionBuilder:(child,animation)=>FadeTransition(opacity:animation,child:child), child:showingChannels?Row(key:const ValueKey('list'),
            children:[rail(), Expanded(child:ColoredBox(color:panel, child:Column(children:[ServerHeader(id:serverId!),
              Row(children:[const Expanded(child:Padding(padding:EdgeInsets.all(12), child:Text('Canais', style:TextStyle(fontSize:18)))),
                IconButton(onPressed:createChannel, icon:const Icon(Icons.add)), IconButton(onPressed:createInvite,
              icon:const Icon(Icons.share)
)
]), Expanded(child:channelList(docs))
])))]
):Column(key:const ValueKey('chat'), children:[ListTile(leading:IconButton(icon:const Icon(Icons.menu),
        onPressed:()=>setState(()=>showingChannels=true)
), title:Text('# $activeName')), Expanded(child:active==null?const Center(child:Text('Sem canais')):MessageThread(key:ValueKey('$serverId/$active'),
          collection:db.collection('servers').doc(serverId).collection('channels').doc(active).collection('messages'),
        uid:myUid, serverId:serverId, threadId:'server:$serverId:$active'
))])));
}
);
}
    @override Widget build(BuildContext c)=>PopScope(
      canPop: !(tab == 0 && !showingChannels),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && tab == 0 && !showingChannels) {
          setState(() => showingChannels = true);
        }
      },
      child:Scaffold(appBar:AppBar(title:const MeowTitle()), body:Column(children:[Expanded(child:AnimatedSwitcher(duration:const Duration(milliseconds:240),switchInCurve:Curves.easeOutCubic,switchOutCurve:Curves.easeInCubic,
      transitionBuilder:(child, a)=>FadeTransition(opacity:a, child:SlideTransition(position:Tween<Offset>(begin:const Offset(.015,
    0
), end:Offset.zero).animate(CurvedAnimation(parent:a,curve:Curves.easeOutCubic)), child:child)), child:KeyedSubtree(key:ValueKey(tab), child:switch(tab){
      1=>FriendsPage(uid:myUid),
      2=>DmListPage(uid:myUid),
      3=>ProfilePage(uid:myUid),
      _=>serverContent()
}
)
)), if (tab != 0 || showingChannels) NavigationBar(height:70, selectedIndex:tab, onDestinationSelected:(i)=>setState(()=>tab=i), destinations:const [NavigationDestination(icon:Icon(Icons.tag),
  label:'Canais'
), NavigationDestination(icon:Icon(Icons.people), label:'Amigos'), NavigationDestination(icon:Icon(Icons.chat_bubble_outline),
  label:'DMs'
), NavigationDestination(icon:Icon(Icons.person), label:'Perfil')])])));
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
    final existingDm = await dm.get();
    if (!existingDm.exists) await dm.set({'members': [me, other]});
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
  final String id,
  other,
  uid;
  const DmChatPage({
    super.key,
    required this.id,
    required this.other,
    required this.uid
}
);
    @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:StreamBuilder<DocumentSnapshot<Map<String,
  dynamic>>>(stream:db.collection('users').doc(other).snapshots(), builder:(c, s)=>Text(s.data?.data()?['displayName']?.toString()??s.data?.data()?['username']?.toString()??'DM'))
), body:DmPermissionGate(id:id,uid:uid,other:other));
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
  final String? serverId;
  const MessageThread({
    super.key,
    required this.collection,
    required this.uid,
    required this.threadId,
    this.serverId
}
);
  @override State<MessageThread> createState()=>_MessageThreadState();
}

class _MessageThreadState extends State<MessageThread> {
  final input=TextEditingController();
  bool sending=false;
  Timestamp? lastMarkedMessage;
  String? replyId,
  replyText,
  replyAuthor;
  @override void dispose(){
    input.dispose();
    super.dispose();
}
  Future<void> markRead()async{
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
    dynamic>? attachment
}
)async{
    final text=input.text.trim();
    if((text.isEmpty&&attachment==null)||sending)return;
    setState(()=>sending=true);
    try{
      final u=(await db.collection('users').doc(widget.uid).get()).data()??{
}
;
      final data=<String,
      dynamic>{
        'text':text,
        'authorId':widget.uid,
        'author':u['displayName']??u['username']??'Usuário',
        'createdAt':FieldValue.serverTimestamp()
}
;
      if(replyId!=null){
        data.addAll({
          'replyToId':replyId,
          'replyText':replyText,
          'replyAuthor':replyAuthor
}
);
}
      if(attachment!=null)data['attachment']=attachment;
      await widget.collection.add(data);
      input.clear();
      if(mounted)setState((){
        replyId=null;
        replyText=null;
        replyAuthor=null;
}
);
      await markRead();
}catch(e){
      if(mounted)notice(context, 'Falha ao enviar: $e');
}finally{
      if(mounted)setState(()=>sending=false);
}
}
  bool uploading = false;
  Future<void> attach() async {
    if (uploading || sending) return;
    setState(() => uploading = true);
    try {
      final source = await showModalBottomSheet<String>(
        context: context,
        builder: (c) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo), title: const Text('Galeria'),
            onTap: () => Navigator.pop(c, 'gallery')),
          ListTile(leading: const Icon(Icons.folder), title: const Text('Arquivos (25 MiB)'),
            onTap: () => Navigator.pop(c, 'files')),
        ])),
      );
      if (!mounted || source == null) return;
      final file = source == 'gallery'
          ? await ImagePicker().pickImage(source: ImageSource.gallery, requestFullMetadata: false)
          : await files.openFile();
      if (file == null) return;
      final length = await file.length();
      if (length == 0 || length > attachmentLimit) {
        throw Exception('O arquivo precisa ter entre 1 byte e 25 MiB.');
      }
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
            await for (final chunk in file.openRead()) {
              request.sink.add(chunk);
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
        children:[ListTile(leading:const Icon(Icons.reply), title:const Text('Responder'), onTap:()=>Navigator.pop(c,
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
    if(action=='reply')setState((){
      replyId=doc.id;
      replyText=d['text']?.toString()??'';
      replyAuthor=d['author']?.toString()??'Usuário';
}
);
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
    @override Widget build(BuildContext c)=>Column(children:[Expanded(child:StreamBuilder<QuerySnapshot<Map<String,
      dynamic>>>(stream:widget.collection.orderBy('createdAt', descending:true).limit(100).snapshots(),
      builder:(c, s){
        if(s.hasError)return Center(child:Text('Erro: ${s.error}'));
        if(!s.hasData)return const Center(child:CircularProgressIndicator());
        final docs=s.data!.docs;
        if(docs.isEmpty)return const Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Image(image:AssetImage('assets/meow_foreground.png'),width:72,height:72),SizedBox(height:12),Text('Comece a conversa!')]));
        final newest = docs.first.data()['createdAt'];
        if (newest is Timestamp && newest != lastMarkedMessage) {
          lastMarkedMessage = newest;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) markRead();
          });
        }
          return ListView.builder(reverse:true, padding:const EdgeInsets.all(12), itemCount:docs.length, itemBuilder:(c,
        i
){
          final doc=docs[i],
          d=doc.data();
          final author=d['authorId']?.toString()??'';
          final attachment=d['attachment'];
          final older=i+1<docs.length?docs[i+1].data():null;
          final grouped=older!=null && older['authorId']==author && older['createdAt'] is Timestamp && d['createdAt'] is Timestamp && (d['createdAt'] as Timestamp).toDate().difference((older['createdAt'] as Timestamp).toDate()).inMinutes.abs()<5;
          final when=d['createdAt'] is Timestamp?formatMeowTime((d['createdAt'] as Timestamp).toDate()):'Enviando...';
            return InkWell(onLongPress:()=>options(doc), child:Padding(padding:const EdgeInsets.symmetric(vertical:6),
              child:Row(crossAxisAlignment:CrossAxisAlignment.start, children:[grouped?const SizedBox(width:40):ProfileAvatar(uid:author), const SizedBox(width:10),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[if(!grouped)Row(children:[Flexible(child:InkWell(onTap:()=>openProfile(c,author),child:Text(d['author']?.toString()??'Usuário',style:const TextStyle(fontWeight:FontWeight.bold,color:purple)))),const SizedBox(width:8),Text(when,style:const TextStyle(fontSize:11,color:Colors.white54))]), if(d['replyToId']!=null)Text('↳ ${d['replyAuthor']??''}: ${d['replyText']??''}', maxLines:2,
              overflow:TextOverflow.ellipsis, style:const TextStyle(color:Colors.white60, fontSize:12)
), if((d['text']?.toString()??'').isNotEmpty)Text(d['text'].toString()), if(attachment is Map&&attachment['id'] is String)AttachmentView(attachment:attachment),
              if(d['editedAt']!=null)const Text('(editada)', style:TextStyle(fontSize:11, color:Colors.white54))
]))
])
));
}
);
}
)
), if(replyId!=null)ListTile(dense:true, title:Text('Respondendo a $replyAuthor: $replyText', maxLines:1,
  overflow:TextOverflow.ellipsis
), trailing:IconButton(icon:const Icon(Icons.close), onPressed:()=>setState((){
    replyId=null;
    replyText=null;
    replyAuthor=null;
}
))), SafeArea(top:false, child:Padding(padding:const EdgeInsets.all(8), child:Row(children:[IconButton(tooltip:'Anexar arquivo',
  onPressed:(sending||uploading)?null:attach, icon:Icon(uploading?Icons.hourglass_top:Icons.add_circle_outline)
), Expanded(child:TextField(controller:input, maxLength:2000, maxLines:4, minLines:1, decoration:const InputDecoration(hintText:'Mensagem',
  counterText:''
), onSubmitted:(_)=>send())), IconButton(onPressed:sending?null:()=>send(), icon:const Icon(Icons.send,
  color:purple
))])))]);
}

class AttachmentView extends StatefulWidget {
  final Map attachment;
  const AttachmentView({
    super.key,
    required this.attachment
}
);
  @override State<AttachmentView> createState()=>_AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView>{
  Future<Uint8List?>? imageFuture;
  Future<Uint8List?> fetch() => PrivateMediaCache.get(
    attachmentUrl(widget.attachment['id'].toString()),
  );
  @override void initState(){
    super.initState();
    if((widget.attachment['contentType']?.toString()??'').startsWith('image/'))imageFuture=fetch();
}
  @override Widget build(BuildContext c){
    final name=widget.attachment['name']?.toString()??'Arquivo';
      return Column(crossAxisAlignment:CrossAxisAlignment.start, children:[if(imageFuture!=null)FutureBuilder<Uint8List?>(future:imageFuture,
        builder:(c, s)=>s.data==null?const SizedBox(height:36, child:Text('Carregando imagem...')):ConstrainedBox(constraints:const BoxConstraints(maxHeight:250,
      maxWidth:300
), child:Image.memory(s.data!, fit:BoxFit.contain, errorBuilder:(c, e, st)=>const Text('Imagem indisponível')))
), Text('📎 $name', style:const TextStyle(color:purple))]);
}
}

class FriendsPage extends StatelessWidget {
  final String uid;
  const FriendsPage({super.key,required this.uid});
  @override Widget build(BuildContext c)=>Scaffold(
    body:Column(children:[const ListTile(title:Text('Amigos',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold))),
      Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:TextField(
        decoration:const InputDecoration(labelText:'Buscar usuário',prefixIcon:Icon(Icons.search)),
        onSubmitted:(name)async{
          final n=cleanName(name);
          final found=await db.collection('users').where('username',isEqualTo:n).limit(1).get();
          if(!c.mounted)return;
          if(found.docs.isEmpty){notice(c,'Usuário não encontrado');return;}
          openProfile(c,found.docs.first.id);
        })),
      Expanded(child:RelationshipListPage(uid:uid,kind:'friends')),
    ]));
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
      const Text('Meow'),const SizedBox(width:8),
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
 @override Widget build(BuildContext c)=>StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:receiptRef(threadId,uid).snapshots(),builder:(c,r){
  final seen=r.data?.data()?['at'] as Timestamp?;
  return StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:collection.orderBy('createdAt',descending:true).limit(30).snapshots(),builder:(c,s){
   final unread=s.data?.docs.any((d){final t=d.data()['createdAt'];return d.data()['authorId']!=uid&&t is Timestamp&&(seen==null||t.compareTo(seen)>0);})??false;
   return unread?const Icon(Icons.circle,color:Color(0xFF39F57A),size:12):const SizedBox.shrink();
  });
 });
}
class ServerUnreadDot extends StatelessWidget{
 final String serverId,uid;const ServerUnreadDot({super.key,required this.serverId,required this.uid});
 @override Widget build(BuildContext c)=>StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('servers').doc(serverId).collection('channels').snapshots(),builder:(c,s){
  if(s.hasError || s.data?.docs.isEmpty != false)return const SizedBox.shrink();
  return SizedBox(width:12,height:12,child:Stack(children:[for(final ch in s.data!.docs)ThreadUnreadDot(threadId:'server:$serverId:${ch.id}',uid:uid,collection:ch.reference.collection('messages'))]));
 });
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
  final String id, uid, other;
  const DmPermissionGate({super.key, required this.id, required this.uid, required this.other});
  @override
  Widget build(BuildContext context) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
    stream: db.collection('users').doc(uid).collection('following').doc(other).snapshots(),
    builder: (context, mine) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('users').doc(other).collection('following').doc(uid).snapshots(),
      builder: (context, theirs) {
        if (mine.hasError || theirs.hasError) return const Center(child: Text('Nao foi possivel verificar a amizade.'));
        if (!mine.hasData || !theirs.hasData) return const Center(child: CircularProgressIndicator());
        if (mine.data!.exists && theirs.data!.exists) {
          return MessageThread(collection: db.collection('dms').doc(id).collection('messages'), uid: uid, threadId: 'dm:$id');
        }
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: db.collection('dmRequests').doc(id).snapshots(),
          builder: (context, request) {
            if (request.hasError) return Center(child: Text('Erro: ${request.error}'));
            if (!request.hasData) return const Center(child: CircularProgressIndicator());
            final data = request.data!.data();
            if (data?['status'] == 'accepted') {
              return MessageThread(collection: db.collection('dms').doc(id).collection('messages'), uid: uid, threadId: 'dm:$id');
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
