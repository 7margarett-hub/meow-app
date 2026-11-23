import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_selector/file_selector.dart' as files;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
const bg = Color(0xFF111218), panel = Color(0xFF1C1D28), purple = Color(0xFF8B5CF6);
const avatarLimit = 8 * 1024 * 1024, bannerLimit = 15 * 1024 * 1024, attachmentLimit = 25 * 1024 * 1024;
const imageHost = 'ffxsvctvcsldumxnkiob.supabase.co';
final changedImage = ValueNotifier<Uri?>(null);
final db = FirebaseFirestore.instance;
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
      theme: ThemeData.dark(useMaterial3:true).copyWith(scaffoldBackgroundColor:bg, colorScheme:ColorScheme.fromSeed(seedColor:purple,
    brightness:Brightness.dark
), appBarTheme:const AppBarTheme(backgroundColor:panel), inputDecorationTheme:InputDecorationTheme(filled:true,
    fillColor:panel, border:OutlineInputBorder(borderRadius:BorderRadius.circular(14))
),), home:StreamBuilder<User?>(stream:FirebaseAuth.instance.authStateChanges(), builder:(c, s) => s.connectionState == ConnectionState.waiting ? const LoadingCat() : s.data == null ? const LoginPage() : const SocialHome()),
);
}

class LoadingCat extends StatefulWidget {
  const LoadingCat({
    super.key
}
);
  @override State<LoadingCat> createState()=>_LoadingCatState();
}

class _LoadingCatState extends State<LoadingCat> with SingleTickerProviderStateMixin {
  late final AnimationController spin = AnimationController(vsync:this, duration:const Duration(milliseconds:1600))..repeat();
  @override void dispose(){
    spin.dispose();
    super.dispose();
}
    @override Widget build(BuildContext c)=>Scaffold(backgroundColor:Colors.black, body:Center(child:RotationTransition(turns:spin,
  child:const Icon(Icons.pets, color:Colors.white, size:100)
)));
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
        children:[const Icon(Icons.pets, size:72, color:purple), const SizedBox(height:18), Text(register?'Criar conta Meow':'Entrar no Meow',
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
  Future<Uint8List?> fetch() async {
    try {
      final r=await http.get(widget.url, headers:await authHeaders()).timeout(const Duration(seconds:30));
      return r.statusCode==200?r.bodyBytes:null;
}catch(_){
      return null;
}
}
  void refresh(){
    if(changedImage.value==widget.url&&mounted)setState(()=>future=fetch());
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
)=>placeholder);
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
)), ListTile(leading:const Icon(Icons.folder), title:const Text('Arquivos'), onTap:()=>Navigator.pop(c,
        'files'
)),]
)));
      if(source==null)return;
        final f=source=='gallery'?await ImagePicker().pickImage(source:ImageSource.gallery, requestFullMetadata:false):await files.openFile(acceptedTypeGroups:const [files.XTypeGroup(label:'Imagens',
      extensions:['jpg', 'jpeg', 'png', 'webp', 'gif']
)]);
      if(f==null)return;
      final limit=widget.slot=='banner'?bannerLimit:avatarLimit;
      if(await f.length()>limit)throw Exception('Limite de ${limit~/1048576} MiB.');
        final r=await http.put(mediaUrl(widget.scope, widget.id, widget.slot), headers:await authHeaders(),
      body:await f.readAsBytes()
).timeout(const Duration(seconds:120));
      if(r.statusCode!=200)throw Exception('Upload falhou: ${r.statusCode} ${r.body}');
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
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    if(s.hasError)return const Center(child:Text('Perfil indisponível.'));
    final d=s.data?.data()??{
}
;
    final username=d['username']?.toString()??'meow';
    final own=uid==FirebaseAuth.instance.currentUser?.uid;
    final p=d['presence']?.toString()??'offline';
      return ListView(controller:scrollController, children:[Stack(clipBehavior:Clip.none, children:[PrivateImage(scope:'profile',
    id:uid, slot:'banner', size:180, borderRadius:BorderRadius.zero
), Positioned(left:18, bottom:-44, child:Container(padding:const EdgeInsets.all(4), decoration:const BoxDecoration(color:panel,
    shape:BoxShape.circle
), child:PrivateImage(scope:'profile', id:uid, slot:'avatar', size:88)))]), const SizedBox(height:55),
        Padding(padding:const EdgeInsets.all(18), child:Column(crossAxisAlignment:CrossAxisAlignment.start,
          children:[Text(d['displayName']?.toString()??username, style:const TextStyle(fontSize:24, fontWeight:FontWeight.bold)),
          Text('@$username', style:const TextStyle(color:Colors.white60)), if((d['pronouns']?.toString()??'').isNotEmpty)Text(d['pronouns'].toString()),
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
, icon:const Icon(Icons.message), label:const Text('Enviar mensagem'))), if(own&&!expanded)TextButton.icon(onPressed:()=>FirebaseAuth.instance.signOut(),
          icon:const Icon(Icons.logout), label:const Text('Sair da conta')
),
]
))
]);
}
);
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
          return ListView(children:[Stack(clipBehavior:Clip.none, children:[PrivateImage(scope:'profile', id:widget.uid,
        slot:'banner', size:180, borderRadius:BorderRadius.zero
), Positioned(right:10, top:10, child:ChangeImage('profile', widget.uid, 'banner', 'Trocar banner',
        iconOnly:true
)), Positioned(left:18, bottom:-45, child:Stack(alignment:Alignment.bottomRight, children:[PrivateImage(scope:'profile',
        id:widget.uid, slot:'avatar', size:90
), ChangeImage('profile', widget.uid, 'avatar', 'Trocar foto', iconOnly:true)]))]), const SizedBox(height:64),
            Padding(padding:const EdgeInsets.all(18), child:Column(children:[TextField(controller:name, maxLength:40,
          decoration:const InputDecoration(labelText:'Nome de exibição')
), const SizedBox(height:10), TextField(controller:pronouns, maxLength:40, decoration:const InputDecoration(labelText:'Pronomes')),
            const SizedBox(height:10), TextField(controller:bio, maxLength:300, maxLines:4, decoration:const InputDecoration(labelText:'Biografia')),
            const SizedBox(height:10), TextField(controller:custom, maxLength:100, decoration:const InputDecoration(labelText:'Status personalizado')),
              DropdownButtonFormField<String>(value:presence, decoration:const InputDecoration(labelText:'Disponibilidade'),
              items:presenceLabels.entries.map((e)=>DropdownMenuItem(value:e.key, child:Text(e.value))).toList(),
              onChanged:(v){
                if(v!=null)setState(()=>presence=v);
}
), const SizedBox(height:20), SizedBox(width:double.infinity, child:FilledButton(onPressed:busy?null:save,
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
      return Column(children:[PrivateImage(scope:'server', id:id, slot:'banner', size:160, borderRadius:BorderRadius.zero),
        ListTile(leading:PrivateImage(scope:'server', id:id, slot:'avatar', size:42), title:Text(d['name']?.toString()??'Servidor'),
          subtitle:Text('${(d['members'] as List?)?.length??0} membros'), trailing:d['ownerId']==myUid?IconButton(icon:const Icon(Icons.settings),
        onPressed:()=>Navigator.push(c, MaterialPageRoute(builder:(_)=>ServerSettingsPage(id:id)))
):null
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
        if(d['ownerId']!=myUid)return const Center(child:Text('Somente o proprietário pode editar.'));
          return ListView(children:[PrivateImage(scope:'server', id:id, slot:'banner', size:160), const SizedBox(height:16),
            Center(child:PrivateImage(scope:'server', id:id, slot:'avatar', size:88)), Padding(padding:const EdgeInsets.all(18),
              child:Column(children:[Text(d['name']?.toString()??'Servidor', style:const TextStyle(fontSize:22)),
                const SizedBox(height:18), ChangeImage('server', id, 'avatar', 'Trocar ícone (8 MiB)'), ChangeImage('server',
              id, 'banner', 'Trocar banner (15 MiB)'
)
])
)
]);
}
)
);
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
  Future<String?> prompt(String title, String hint, {
    int maxLength=40
}
)async{
    final t=TextEditingController();
      final result=await showDialog<String>(context:context, builder:(c)=>AlertDialog(title:Text(title),
        content:TextField(controller:t, maxLength:maxLength, decoration:InputDecoration(hintText:hint)), actions:[TextButton(onPressed:()=>Navigator.pop(c),
      child:const Text('Cancelar')
), FilledButton(onPressed:()=>Navigator.pop(c, t.text.trim()), child:const Text('Confirmar'))]
));
    t.dispose();
    return result;
}
  Future<void> createServer()async{
    final n=await prompt('Criar servidor', 'Nome');
    if(n==null||n.isEmpty)return;
    try{
      final ref=await db.collection('servers').add({
        'name':n,
        'ownerId':myUid,
        'members':[myUid],
        'createdAt':FieldValue.serverTimestamp()
}
);
      await ref.collection('channels').add({
        'name':'geral',
        'category':'GERAL',
        'createdAt':FieldValue.serverTimestamp()
}
);
      if(mounted)setState((){
        serverId=ref.id;
        channelId=null;
        showingChannels=true;
}
);
}catch(e){
      if(mounted)notice(context, e);
}
}
  Future<void> createChannel()async{
    if(serverId==null)return;
    final n=await prompt('Criar canal', 'Nome');
    if(n==null||n.isEmpty)return;
    final category=await prompt('Categoria', 'GERAL');
    if(category==null)return;
    try{
      await db.collection('servers').doc(serverId).collection('channels').add({
        'name':n,
        'category':category.isEmpty?'GERAL':category.toUpperCase(),
        'createdAt':FieldValue.serverTimestamp()
}
);
}catch(e){
      if(mounted)notice(context, e);
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
    if(code==null||code.isEmpty)return;
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
), icon:PrivateImage(scope:'server', id:d.id, slot:'avatar', size:36))
)]))
)])));
  Widget channelList(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs){
    final groups=<String,
    List<QueryDocumentSnapshot<Map<String,
    dynamic>>>>{
}
;
    for(final d in docs){
      final cat=(d.data()['category']?.toString()??'GERAL').toUpperCase();
      groups.putIfAbsent(cat, ()=>[]).add(d);
}
      return ListView(children:[for(final g in groups.entries)...[ListTile(dense:true, title:Text(g.key,
    style:const TextStyle(fontSize:12, color:Colors.white70)
), leading:Icon(collapsed.contains(g.key)?Icons.chevron_right:Icons.expand_more), onTap:()=>setState((){
      if(!collapsed.add(g.key))collapsed.remove(g.key);
}
),), if(!collapsed.contains(g.key))for(final d in g.value)ListTile(leading:const Icon(Icons.tag),
      title:Text(d.data()['name']?.toString()??'canal'), onTap:()=>setState((){
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
, child:AnimatedSwitcher(duration:const Duration(milliseconds:250), child:showingChannels?Row(key:const ValueKey('list'),
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
    @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('🐱 Meow'), actions:[IconButton(onPressed:()=>FirebaseAuth.instance.signOut(),
  icon:const Icon(Icons.logout)
)]), body:Column(children:[Expanded(child:AnimatedSwitcher(duration:const Duration(milliseconds:280),
      transitionBuilder:(child, a)=>FadeTransition(opacity:a, child:SlideTransition(position:Tween<Offset>(begin:const Offset(.04,
    0
), end:Offset.zero).animate(a), child:child)), child:KeyedSubtree(key:ValueKey(tab), child:switch(tab){
      1=>FriendsPage(uid:myUid),
      2=>DmListPage(uid:myUid),
      3=>ProfilePage(uid:myUid),
      _=>serverContent()
}
)
)), NavigationBar(height:70, selectedIndex:tab, onDestinationSelected:(i)=>setState(()=>tab=i), destinations:const [NavigationDestination(icon:Icon(Icons.tag),
  label:'Canais'
), NavigationDestination(icon:Icon(Icons.people), label:'Amigos'), NavigationDestination(icon:Icon(Icons.chat_bubble_outline),
  label:'DMs'
), NavigationDestination(icon:Icon(Icons.person), label:'Perfil')])]));
}
String dmId(String a, String b){
  final ids=[a, b]..sort();
  return '${ids[0]}_${ids[1]}';
}
Future<void> openDm(BuildContext context, String other)async{
  final me=FirebaseAuth.instance.currentUser?.uid;
  if(me==null||other==me||other.isEmpty)return;
  final id=dmId(me, other);
  try{
    await db.collection('dms').doc(id).set({
      'members':[me, other]
}
, SetOptions(merge:true));
      if(context.mounted)Navigator.push(context, MaterialPageRoute(builder:(_)=>DmChatPage(id:id, other:other,
    uid:me
)));
}catch(e){
    if(context.mounted)notice(context, e);
}
}

class DmListPage extends StatelessWidget {
  final String uid;
  const DmListPage({
    super.key,
    required this.uid
}
);
    @override Widget build(BuildContext c)=>Column(children:[const ListTile(title:Text('Mensagens privadas',
  style:TextStyle(fontSize:22, fontWeight:FontWeight.bold)
)), Expanded(child:StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(stream:db.collection('dms').where('members',
  arrayContains:uid
).snapshots(), builder:(c, s){
    if(s.hasError)return Center(child:Text('Erro: ${s.error}'));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    if(s.data!.docs.isEmpty)return const Center(child:Text('Abra o perfil de alguém para conversar.'));
    return ListView(children:[for(final d in s.data!.docs)Builder(builder:(c){
      final others=List<String>.from(d.data()['members']??[]).where((x)=>x!=uid).toList();
      if(others.isEmpty)return const SizedBox.shrink();
      final other=others.first;
      return StreamBuilder<DocumentSnapshot<Map<String,
        dynamic>>>(stream:db.collection('users').doc(other).snapshots(), builder:(c, u)=>ListTile(leading:ProfileAvatar(uid:other),
        title:Text(u.data?.data()?['displayName']?.toString()??u.data?.data()?['username']?.toString()??'Usuário'),
          subtitle:UnreadLabel(threadId:'dm:${d.id}', uid:uid), onTap:()=>Navigator.push(c, MaterialPageRoute(builder:(_)=>DmChatPage(id:d.id,
        other:other, uid:uid
)))
));
}
)]);
}
))]);
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
), body:MessageThread(collection:db.collection('dms').doc(id).collection('messages'), uid:uid, threadId:'dm:$id'));
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
  Future<void> attach()async{
    try{
        final source=await showModalBottomSheet<String>(context:context, builder:(c)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,
          children:[ListTile(leading:const Icon(Icons.photo), title:const Text('Galeria'), onTap:()=>Navigator.pop(c,
        'gallery'
)), ListTile(leading:const Icon(Icons.folder), title:const Text('Arquivos (25 MiB)'), onTap:()=>Navigator.pop(c,
        'files'
))]
)));
      if(source==null)return;
      final f=source=='gallery'?await ImagePicker().pickImage(source:ImageSource.gallery, requestFullMetadata:false):await files.openFile();
      if(f==null)return;
      if(await f.length()>attachmentLimit)throw Exception('Arquivo maior que 25 MiB.');
      final name=f.name;
      final extension=name.contains('.')?name.split('.').last.toLowerCase():'';
      const mime={
        'jpg':'image/jpeg',
        'jpeg':'image/jpeg',
        'png':'image/png',
        'gif':'image/gif',
        'webp':'image/webp',
        'pdf':'application/pdf',
        'txt':'text/plain',
        'mp4':'video/mp4'
}
;
      final contentType=mime[extension]??'application/octet-stream';
      // Requires an authenticated meow-anexos Edge Function accepting PUT bytes,
      // returning JSON {id, name, contentType, size} and authorizing GET by ID.
      // Stream the file rather than loading up to 25 MiB into memory.
      final request = http.StreamedRequest('PUT', Uri.https(
        imageHost,
        '/functions/v1/meow-anexos',
        {'thread': widget.threadId, 'name': name},
      ));
      request.headers.addAll({
        ...await authHeaders(),
        'Content-Type': contentType,
      });
      final length = await f.length();
      request.contentLength = length;
      final upload = f.openRead().listen(
        request.sink.add,
        onError: request.sink.addError,
        onDone: request.sink.close,
        cancelOnError: true,
      );
      http.Response r;
      try {
        final client = http.Client();
        try {
          final streamed = await client.send(request).timeout(
            const Duration(minutes: 3),
          );
          r = await http.Response.fromStream(streamed);
        } finally {
          client.close();
        }
      } finally {
        await upload.cancel();
      }
      if (r.statusCode != 200 && r.statusCode != 201) {
        throw Exception('Falha no upload (HTTP ${r.statusCode}): ${r.body}');
      }
      final payload = jsonDecode(r.body);
      if(payload is! Map||payload['id'] is! String)throw Exception('Resposta inválida do servidor de anexos.');
      await send(attachment:{
        'id':payload['id'],
        'name':name,
        'contentType':contentType,
        'size':await f.length()
}
);
}catch(e){
      if(mounted)notice(context, e);
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
)), if(own)ListTile(leading:const Icon(Icons.edit), title:const Text('Editar'), onTap:()=>Navigator.pop(c,
      'edit'
)), if(canDelete)ListTile(leading:const Icon(Icons.delete), title:const Text('Apagar'), onTap:()=>Navigator.pop(c,
      'delete'
))]
)));
    if(!mounted)return;
    if(action=='reply')setState((){
      replyId=doc.id;
      replyText=d['text']?.toString()??'';
      replyAuthor=d['author']?.toString()??'Usuário';
}
);
    if(action=='edit'&&own){
      final t=TextEditingController(text:d['text']?.toString()??'');
        final v=await showDialog<String>(context:context, builder:(c)=>AlertDialog(title:const Text('Editar mensagem'),
          content:TextField(controller:t, maxLength:2000, maxLines:4), actions:[TextButton(onPressed:()=>Navigator.pop(c),
        child:const Text('Cancelar')
), FilledButton(onPressed:()=>Navigator.pop(c, t.text.trim()), child:const Text('Salvar'))]
));
      t.dispose();
      if(v!=null&&v.isNotEmpty){
        try{
          await doc.reference.update({
            'text':v,
            'editedAt':FieldValue.serverTimestamp()
}
);
}catch(e){
          if(mounted)notice(context, e);
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
        if(docs.isEmpty)return const Center(child:Text('Diga oi! 👋'));
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
            return InkWell(onLongPress:()=>options(doc), child:Padding(padding:const EdgeInsets.symmetric(vertical:6),
              child:Row(crossAxisAlignment:CrossAxisAlignment.start, children:[ProfileAvatar(uid:author), const SizedBox(width:10),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[InkWell(onTap:()=>openProfile(c,
              author
), child:Text(d['author']?.toString()??'Usuário', style:const TextStyle(fontWeight:FontWeight.bold,
              color:purple
))), if(d['replyToId']!=null)Text('↳ ${d['replyAuthor']??''}: ${d['replyText']??''}', maxLines:2,
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
  onPressed:sending?null:attach, icon:const Icon(Icons.add_circle_outline)
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
  Future<Uint8List?> fetch()async{
    try{
      final r=await http.get(attachmentUrl(widget.attachment['id'].toString()), headers:await authHeaders());
      return r.statusCode==200?r.bodyBytes:null;
}catch(_){
      return null;
}
}
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

class FriendsPage extends StatefulWidget {
  final String uid;
  const FriendsPage({
    super.key,
    required this.uid
}
);
  @override State<FriendsPage> createState()=>_FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage>{
  final username=TextEditingController();
  @override void dispose(){
    username.dispose();
    super.dispose();
}
  Future<void> add()async{
    final n=cleanName(username.text);
    if(n.isEmpty)return;
    try{
      final found=await db.collection('users').where('username', isEqualTo:n).limit(1).get();
      if(found.docs.isEmpty)throw Exception('Usuário não encontrado');
      final other=found.docs.first.id;
      if(other==widget.uid)throw Exception('Você não pode adicionar a si mesmo');
      await db.collection('users').doc(widget.uid).collection('friends').doc(other).set({
        'username':n,
        'createdAt':FieldValue.serverTimestamp()
}
);
      username.clear();
      if(mounted)notice(context, 'Amigo adicionado!');
}catch(e){
      if(mounted)notice(context, e);
}
}
    @override Widget build(BuildContext c)=>Padding(padding:const EdgeInsets.all(16), child:Column(children:[const Align(alignment:Alignment.centerLeft,
  child:Text('Amigos', style:TextStyle(fontSize:24, fontWeight:FontWeight.bold))
), const SizedBox(height:14), Row(children:[Expanded(child:TextField(controller:username, decoration:const InputDecoration(hintText:'Nome de usuário'))),
  IconButton(onPressed:add, icon:const Icon(Icons.person_add, color:purple))
]), Expanded(child:StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(stream:db.collection('users').doc(widget.uid).collection('friends').snapshots(),
      builder:(c, s)=>ListView(children:[for(final d in s.data?.docs??[])ListTile(leading:ProfileAvatar(uid:d.id),
    title:Text(d.data()['username']?.toString()??'?'), onTap:()=>openProfile(c, d.id)
)])
))]));
}
