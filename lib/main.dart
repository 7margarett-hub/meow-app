import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';
import 'package:get_thumbnail_video/index.dart' show ImageFormat;
import 'package:shared_preferences/shared_preferences.dart';
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
import 'package:url_launcher/url_launcher.dart';
import 'package:app_links/app_links.dart';
import 'package:share_plus/share_plus.dart';
import 'package:photo_manager/photo_manager.dart' as gallery;
late final AppLinks meowAppLinks;
const bg = Color(0xFF1A1A1E), panel = Color(0xFF242429), purple = Color(0xFF8B5CF6);
const meowComposerColor = Color(0xFF29292F);
const double meowChatAvatarSize = 44;
// The heartbeat and its local expiry must always use the same constants.
const meowPresenceInterval = Duration(minutes:2);
const meowPresenceExpiry = Duration(minutes:5);
class MeowQuietLog {
  static final _last=<String,DateTime>{};
  static void warning(String key,String message){
    final now=DateTime.now();final last=_last[key];
    if(last!=null&&now.difference(last)<const Duration(minutes:5))return;
    if(_last.length>=64&&!_last.containsKey(key))_last.remove(_last.keys.first);
    _last[key]=now;debugPrint(message);
  }
}
const avatarLimit = 8 * 1024 * 1024, bannerLimit = 15 * 1024 * 1024, attachmentLimit = 25 * 1024 * 1024;
const imageHost = 'ffxsvctvcsldumxnkiob.supabase.co';
final changedImage = ValueNotifier<Uri?>(null);
final db = FirebaseFirestore.instance;
final meowNavigator = GlobalKey<NavigatorState>();
final meowRouteObserver = RouteObserver<ModalRoute<dynamic>>();
final activeThread = ValueNotifier<String?>(null);
const _meowNativeNotifications=MethodChannel('meow/notifications');
Future<T?> _nativeNotification<T>(String method,[Object? args])async{try{return await _meowNativeNotifications.invokeMethod<T>(method,args);}on MissingPluginException{return null;}on PlatformException catch(e){debugPrint('Meow notificações nativas: ${e.code}');return null;}}
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
  if(response.statusCode!=200)throw Exception('Serviço de contas recusou a operação (HTTP ${response.statusCode}).');
  final result=jsonDecode(response.body);
  if(result is! Map||result['ok']!=true)throw Exception('Não foi possível confirmar a operação.');
}
String currentPresence(Map<String,dynamic>? d) {
  final p=d?['presence']?.toString()??'offline';
  final t=d?['lastSeen'];final closed=d?['presenceClosedAt'];
  if(p=='invisible'||t is! Timestamp||(closed is Timestamp&&closed.compareTo(t)>=0)||DateTime.now().difference(t.toDate())>meowPresenceExpiry)return 'offline';
  return presenceLabels.containsKey(p)?p:'offline';
}
Future<void> notifyMessage(String path) async {
  try {
    final r=await http.post(Uri.https(imageHost,'/functions/v1/meow-notificacoes'),headers:{...await authHeaders(),'Content-Type':'application/json'},body:jsonEncode({'messagePath':path})).timeout(const Duration(seconds:45));
    if(r.statusCode!=200)MeowQuietLog.warning('fcm:${r.statusCode}','Meow FCM: HTTP ${r.statusCode}');
  }catch(e){MeowQuietLog.warning('fcm-network','Meow FCM temporariamente indisponível.');}
}
Future<void> logoutMeow(BuildContext c) async {
  try {
    final uid=myUid; final f=FirebaseMessaging.instance;
    try{await db.collection('users').doc(uid).update({'lastSeen':FieldValue.serverTimestamp(),'presenceClosedAt':FieldValue.serverTimestamp()}).timeout(const Duration(seconds:3));}catch(_){}
    final token=await f.getToken();
    if(token!=null)await db.collection('users').doc(uid).collection('devices').doc(token).delete();
    try {await f.deleteToken();}catch(_){}
  }catch(e){if(c.mounted)notice(c,'Não foi possível desregistrar as notificações: $e');return;}
  await _nativeNotification<void>('clearSession',myUid);
   PrivateMediaCache.clear();await PrivateMediaCache.purgeDisk();await MeowVideoCache.clear();MeowStreams.clear();activeThread.value=null;
  meowNavigator.currentState?.popUntil((route)=>route.isFirst);
  await FirebaseAuth.instance.signOut();
  PrivateMediaCache.clear();await PrivateMediaCache.purgeDisk();
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
  Timer? _idleTimer;
  _MeowFeed(this.source);
  void close(){_idleTimer?.cancel();_idleTimer=null;_epoch++;final old=_subscription;_subscription=null;_last=null;_hasLast=false;old?.cancel();for(final c in _clients.toList()){c.close();}_clients.clear();}
  bool get idle => _clients.isEmpty;
  late final Stream<T> stream = Stream<T>.multi((client) {
    _idleTimer?.cancel();_idleTimer=null;
    _clients.add(client);
    client.onCancel = () {
      _clients.remove(client);
      if (_clients.isEmpty) {
        _idleTimer?.cancel();
        _idleTimer=Timer(const Duration(seconds:5),(){
          if(_clients.isNotEmpty)return;
          _epoch++;final old=_subscription;_subscription=null;_last=null;_hasLast=false;old?.cancel();
        });
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
        for (final k in idle) { entries.remove(k)?.close(); }
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
  static void clear() { for(final f in _documents.values){f.close();}for(final f in _queries.values){f.close();}_documents.clear(); _queries.clear(); }
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

// Bounded RAM cache plus account-scoped, revisioned profile image cache in the OS cache directory.
// Server/channel/DM attachments, legacy unversioned images and other private media stay off disk here.
// Reuse connections and collapse duplicate requests.
class PrivateMediaCache {
  static final _pending=<String,Future<Uint8List?>>{};
  static const diskMaxBytes=512*1024*1024;
  static const diskMaxEntries=2048;
  static const diskTtl=Duration(hours:24);
  static Future<void> _diskTail=Future<void>.value();
  static int _diskEpoch=0;
  static final _safeId=RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final _safeRevision=RegExp(r'^[0-9a-f]{32}$');
  static Future<T> _diskSerial<T>(Future<T> Function() action){
    final next=_diskTail.then((_)=>action());
    _diskTail=next.then<void>((_) {},onError:(Object _,StackTrace __){});
    return next;
  }
  static Future<Directory> _diskRoot()async{
    final base=await getTemporaryDirectory();
    return Directory('${base.path}/meow_profile_cache_v1');
  }
  static bool _diskEligible(Uri url){
    final q=url.queryParameters;
    return url.scheme=='https'&&url.host==imageHost&&_image(url)&&q['scope']=='profile'&&
      _safeId.hasMatch(q['id']??'')&&(const {'avatar','banner'}).contains(q['slot'])&&
      _safeRevision.hasMatch(q['revision']??'')&&q.length==4;
  }
  static String _diskAccount(String key)=>key.split('|').first;
  static Future<Directory> _diskFamily(Uri url,String key)async{
    final root=await _diskRoot();final q=url.queryParameters;
    return Directory('${root.path}/${_diskAccount(key)}/${q['id']}/${q['slot']}');
  }
  static Future<Uint8List?> _readDisk(Uri url,String key,int generation,int session,int diskEpoch)async{
    if(!_diskEligible(url)||!_safeId.hasMatch(_diskAccount(key)))return null;
    return _diskSerial(()async{
      try{
        if(diskEpoch!=_diskEpoch||!_valid(url,key,generation,session))return null;
        final dir=await _diskFamily(url,key);final file=File('${dir.path}/${url.queryParameters['revision']}.bin');
        final stat=await file.stat();final age=DateTime.now().difference(stat.modified);
        final limit=url.queryParameters['slot']=='avatar'?avatarLimit:bannerLimit;
        if(stat.type!=FileSystemEntityType.file)return null;
        if(age.isNegative||age>=diskTtl||stat.size<=0||stat.size>limit){await file.delete();return null;}
        final bytes=await file.readAsBytes();
        return diskEpoch==_diskEpoch&&_valid(url,key,generation,session)&&bytes.length==stat.size?bytes:null;
      }catch(_){return null;}
    });
  }
  static Future<void> _pruneDiskUnlocked()async{
    final root=await _diskRoot();if(!await root.exists())return;
    final entries=<({File file,FileStat stat})>[];var size=0;
    final now=DateTime.now();
    await for(final item in root.list(recursive:true,followLinks:false)){
      if(item is! File)continue;
      try{
        final stat=await item.stat();final age=now.difference(stat.modified);
        if(!item.path.endsWith('.bin')||age.isNegative||age>=diskTtl||stat.size<=0||stat.size>bannerLimit){await item.delete();continue;}
        entries.add((file:item,stat:stat));size+=stat.size;
      }catch(_){}
    }
    entries.sort((a,b)=>a.stat.modified.compareTo(b.stat.modified));
    var count=entries.length;
    for(final entry in entries){
      if(size<=diskMaxBytes&&count<=diskMaxEntries)break;
      try{await entry.file.delete();size-=entry.stat.size;count--;}catch(_){}
    }
  }
  static Future<void> _writeDisk(Uri url,String key,int generation,int session,int diskEpoch,Uint8List bytes)async{
    if(!_diskEligible(url)||!_safeId.hasMatch(_diskAccount(key)))return;
    final limit=url.queryParameters['slot']=='avatar'?avatarLimit:bannerLimit;
    if(bytes.isEmpty||bytes.length>limit)return;
    await _diskSerial(()async{
      File? tmp;
      try{
        if(diskEpoch!=_diskEpoch||!_valid(url,key,generation,session))return;
        final dir=await _diskFamily(url,key);await dir.create(recursive:true);
        final file=File('${dir.path}/${url.queryParameters['revision']}.bin');
        tmp=File('${file.path}.tmp');await tmp.writeAsBytes(bytes,flush:true);
        if(diskEpoch!=_diskEpoch||!_valid(url,key,generation,session))return;
        await tmp.rename(file.path);
        await _pruneDiskUnlocked();
      }catch(_){}finally{if(tmp!=null){try{if(await tmp.exists())await tmp.delete();}catch(_){}}}
    });
  }
  static Future<void> pruneDisk()=>_diskSerial(()async{try{await _pruneDiskUnlocked();}catch(_){}});
  static Future<void> purgeDisk(){
    _diskEpoch++;
    return _diskSerial(()async{try{final root=await _diskRoot();if(await root.exists())await root.delete(recursive:true);}catch(_){}});
  }
  static void _invalidateDisk(Uri url,String key){
    final q=url.queryParameters;
    if(!_image(url)||q['scope']!='profile'||!_safeId.hasMatch(_diskAccount(key))||!_safeId.hasMatch(q['id']??'')||!(const {'avatar','banner'}).contains(q['slot']))return;
    unawaited(_diskSerial(()async{try{final dir=await _diskFamily(url,key);if(await dir.exists())await dir.delete(recursive:true);}catch(_){}}));
  }
  static Future<int> diskBytes()=>_diskSerial(()async{
    var size=0;try{final root=await _diskRoot();if(await root.exists()){await for(final e in root.list(recursive:true,followLinks:false)){if(e is File)size+=await e.length();}}}catch(_){}return size;
  });
  static final _completed=<String,({Uint8List bytes,DateTime time,Future<Uint8List?> future})>{};
  static final _missing=<String,DateTime>{};
  static final _failed=<String,DateTime>{};
  static DateTime? _imageBlockedUntil;
  static int _quotaStreak=0;
  static Duration? retryDelay(Uri url){
    if(!_image(url)||_owner!=FirebaseAuth.instance.currentUser?.uid)return null;
    final now=DateTime.now();final local=_failed[_key(url)];if(local==null)return null;
    final global=_imageBlockedUntil;final until=global!=null&&global.isAfter(local)?global:local;
    final remaining=until.difference(now);
    return (remaining.isNegative?Duration.zero:remaining)+Duration(milliseconds:500+(_key(url).hashCode.abs()%4000));
  }
  static bool _blocked(Uri url)=>_image(url)&&_imageBlockedUntil?.isAfter(DateTime.now())==true;
  static void _failImage(String key,{Duration delay=const Duration(seconds:60)}){
    if(_failed.length>=maxEntries&&!_failed.containsKey(key))_failed.remove(_failed.keys.first);
    _failed[key]=DateTime.now().add(delay);
  }
  static Uint8List? _stale(Uri url,String key){
    if(!_image(url))return null;final entry=_completed[key];if(entry==null)return null;
    if(url.queryParameters['scope']=='server'&&DateTime.now().difference(entry.time)>const Duration(minutes:10))return null;
    return entry.bytes;
  }
  static void _forget(String key){final old=_completed.remove(key);if(old!=null)_usedBytes-=old.bytes.lengthInBytes;_failed.remove(key);}
  static Duration _serverDelay(String? raw){final seconds=int.tryParse(raw??'')??120;return Duration(seconds:seconds.clamp(120,3600).toInt());}

  static final _generation=<String,int>{};
  static final _progress=<String,Set<ValueChanged<double?>>>{};
  static const int maxBytes=48*1024*1024;
  static const int maxEntries=256;
  static const Duration lifetime=Duration(minutes:5);
  static const Duration revisionLifetime=Duration(minutes:30);
  static const Duration attachmentLifetime=Duration(minutes:10);
  static const Duration missingLifetime=Duration(seconds:60);
  static int _usedBytes=0,_session=0,_inFlight=0,_priorityBurst=0;
  static String? _owner;
  static http.Client? _client;
  static final _priorityQueue=<Completer<void>>[],_queue=<Completer<void>>[];
  static String _key(Uri url)=>'${FirebaseAuth.instance.currentUser?.uid??''}|$url';
  static bool _image(Uri url)=>url.path.endsWith('/meow-imagens');
  static Duration _lifetime(Uri url)=>url.path.endsWith('/meow-anexos')?attachmentLifetime:_image(url)&&url.queryParameters.containsKey('revision')?revisionLifetime:lifetime;
  static String _family(String key)=>key.split('&revision=').first;
  static bool _valid(Uri url,String key,int generation,int session)=>_session==session&&FirebaseAuth.instance.currentUser!=null&&_key(url)==key&&(_generation[key]??0)==generation;
  static Future<void> _acquire(bool priority)async{if(_inFlight<4){_inFlight++;return;}final gate=Completer<void>();(priority?_priorityQueue:_queue).add(gate);await gate.future;}
  static void _release(){if(_priorityQueue.isNotEmpty&&(_queue.isEmpty||_priorityBurst<3)){_priorityBurst++;_priorityQueue.removeAt(0).complete();}else if(_queue.isNotEmpty){_priorityBurst=0;_queue.removeAt(0).complete();}else{_inFlight--;_priorityBurst=0;}}
  static void _report(String key,double? value){for(final listener in List<ValueChanged<double?>>.from(_progress[key]??{})){try{listener(value);}catch(_){}}}
  static Future<Uint8List?> get(Uri url,{ValueChanged<double?>? onProgress}) {
    final uid=FirebaseAuth.instance.currentUser?.uid;
    if(uid==null)return Future<Uint8List?>.value(null);
    if(_owner!=uid){if(_owner!=null)unawaited(purgeDisk());clear();_owner=uid;}
    final key=_key(url);final now=DateTime.now();
    final entry=_completed.remove(key);
    if(entry!=null){
      if(now.difference(entry.time)<_lifetime(url)){_completed[key]=entry;if(onProgress!=null)onProgress(1);return entry.future;}
      if(_image(url)&&(url.queryParameters['scope']!='server'||now.difference(entry.time)<const Duration(minutes:10))){_completed[key]=entry;}else{_usedBytes-=entry.bytes.lengthInBytes;}
    }
    if(!_diskEligible(url)&&(_blocked(url)||(_image(url)&&_failed[key]?.isAfter(now)==true))){
      if(_blocked(url))_failImage(key);
      return Future<Uint8List?>.value(_stale(url,key));
    }
    final missing=_missing[key];if(missing!=null){if(now.difference(missing)<missingLifetime)return Future<Uint8List?>.value(null);_missing.remove(key);}
    Future<Uint8List?> observe(Future<Uint8List?> future){if(onProgress==null)return future;final listeners=_progress.putIfAbsent(key,()=> <ValueChanged<double?>>{});listeners.add(onProgress);return future.whenComplete((){listeners.remove(onProgress);if(listeners.isEmpty&&identical(_progress[key],listeners))_progress.remove(key);});}
    final existing=_pending[key];if(existing!=null)return observe(existing);
    final generation=_generation[key]??0,session=_session,diskEpoch=_diskEpoch;
    final task=()async{
      final disk=await _readDisk(url,key,generation,session,diskEpoch);
      if(!_valid(url,key,generation,session))return null;
      if(disk!=null){_store(key,disk);_report(key,1);return disk;}
      if(_blocked(url)||(_image(url)&&_failed[key]?.isAfter(DateTime.now())==true)){
        if(_blocked(url))_failImage(key);return _stale(url,key);
      }
      await _acquire(_image(url));try{return await _download(url,key,generation,session,diskEpoch);}finally{_release();}
    }();
    _pending[key]=task;
    task.whenComplete((){if(identical(_pending[key],task))_pending.remove(key);});
    return observe(task);
  }
  static void _store(String key,Uint8List bytes){
    _missing.remove(key);_failed.remove(key);final old=_completed.remove(key);if(old!=null)_usedBytes-=old.bytes.lengthInBytes;
    if(bytes.isEmpty||bytes.lengthInBytes>maxBytes)return;
    while(_completed.isNotEmpty&&(_usedBytes+bytes.lengthInBytes>maxBytes||_completed.length>=maxEntries)){_usedBytes-=_completed.remove(_completed.keys.first)!.bytes.lengthInBytes;}
    _completed[key]=(bytes:bytes,time:DateTime.now(),future:Future<Uint8List?>.value(bytes));_usedBytes+=bytes.lengthInBytes;
  }
  static Future<Uint8List?> _download(Uri url,String key,int generation,int session,int diskEpoch)async{
    var refreshToken=false;
    for(var attempt=0;attempt<2;attempt++){
      if(!_valid(url,key,generation,session))return null;
      // Check again after acquiring the queue: queued requests must respect backoff.
      if(_blocked(url)){_failImage(key);return _stale(url,key);}
      final pooled=_image(url);final client=pooled?(_client??=http.Client()):http.Client();
      try{
        final headers=await authHeaders(forceRefresh:attempt>0&&refreshToken);if(!_valid(url,key,generation,session))return null;
        final request=http.Request('GET',url)..headers.addAll(headers)..followRedirects=false;
        final response=await client.send(request).timeout(const Duration(seconds:20));
        if(!_valid(url,key,generation,session)){await response.stream.listen((_){}).cancel();return null;}
        if(response.statusCode==200){
          final total=response.contentLength;final limit=url.path.endsWith('/meow-anexos')?attachmentLimit:maxBytes;
          if(total!=null&&total>limit)throw const FormatException('Mídia acima do limite.');
          final builder=BytesBuilder(copy:false);var received=0;var report=DateTime.fromMillisecondsSinceEpoch(0);
          _report(key,total!=null&&total>0?0:null);
          await for(final chunk in response.stream.timeout(const Duration(seconds:20))){if(!_valid(url,key,generation,session))return null;received+=chunk.length;if(received>limit)throw const FormatException('Mídia acima do limite.');builder.add(chunk);final now=DateTime.now();if(now.difference(report)>=const Duration(milliseconds:120)){report=now;_report(key,total!=null&&total>0?(received/total).clamp(0.0,1.0).toDouble():null);}}
          if(!_valid(url,key,generation,session))return null;if(received==0){if(pooled){_failImage(key);return _stale(url,key);}return null;}final bytes=builder.takeBytes();if(pooled&&!_blocked(url))_quotaStreak=0;_store(key,bytes);unawaited(_writeDisk(url,key,generation,session,diskEpoch,bytes));_report(key,1);return bytes;
        }
        // Drain error bodies before reusing the connection.
        await response.stream.drain<void>().timeout(const Duration(seconds:5));
        if(!_valid(url,key,generation,session))return null;
        if(_image(url)){
          if(response.statusCode==401&&attempt==0){refreshToken=true;continue;}
          if(response.statusCode==404){_forget(key);if(_missing.length>=maxEntries)_missing.remove(_missing.keys.first);_missing[key]=DateTime.now();return null;}
          if(response.statusCode==429||response.statusCode==503){
            final now=DateTime.now();
            if(_imageBlockedUntil==null||!_imageBlockedUntil!.isAfter(now))_quotaStreak=min(_quotaStreak+1,4);
            final wait=_serverDelay(response.headers['retry-after']);
            final progressive=Duration(seconds:120*(1<<max(0,_quotaStreak-1)));
            final until=now.add(wait>progressive?wait:progressive);
            if(_imageBlockedUntil==null||until.isAfter(_imageBlockedUntil!))_imageBlockedUntil=until;
            _failImage(key);return _stale(url,key);
          }
          if(response.statusCode>=500||response.statusCode==408){_failImage(key);return _stale(url,key);}
          _forget(key);return null;
        }
        if(response.statusCode!=429&&response.statusCode<500)return null;
      }catch(e){
        MeowQuietLog.warning('media:${url.path}','Meow: falha temporária ao baixar mídia (${url.path}).');
        // Do not close the shared client while other images are downloading.
        if(pooled&&_valid(url,key,generation,session)){_failImage(key);return _stale(url,key);}
      }
      finally{if(!pooled)client.close();}
      if(attempt==0)await Future<void>.delayed(const Duration(milliseconds:400));
    }
    return null;
  }
  static void invalidate(Uri url){
    final key=_key(url);final family=_family(key);_invalidateDisk(url,key);
    final keys=<String>{key,..._completed.keys,..._pending.keys,..._missing.keys,..._failed.keys}.where((k)=>_family(k)==family).toList();
    for(final k in keys){_generation[k]=(_generation[k]??0)+1;final old=_completed.remove(k);if(old!=null)_usedBytes-=old.bytes.lengthInBytes;_pending.remove(k);_missing.remove(k);_failed.remove(k);}
  }
  static void pruneExpired(){
    final now=DateTime.now();for(final k in _completed.keys.toList()){final uri=Uri.tryParse(k.substring(k.indexOf('|')+1));final entry=_completed[k]!;if(uri==null||(!_image(uri)&&now.difference(entry.time)>=_lifetime(uri))||(uri.queryParameters['scope']=='server'&&now.difference(entry.time)>=const Duration(minutes:10))){_completed.remove(k);_usedBytes-=entry.bytes.lengthInBytes;}}
    _missing.removeWhere((_,time)=>now.difference(time)>=missingLifetime);
  }
  static void purgeCompleted(){_completed.clear();_missing.clear();_usedBytes=0;PaintingBinding.instance.imageCache.clear();}
  static void clear(){_session++;_owner=null;_client?.close();_client=null;_generation.clear();_progress.clear();_completed.clear();_missing.clear();_failed.clear();_imageBlockedUntil=null;_quotaStreak=0;_pending.clear();_usedBytes=0;PaintingBinding.instance.imageCache.clear();PaintingBinding.instance.imageCache.clearLiveImages();}
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
Future<Map<String, String>> authHeaders({bool forceRefresh=false}) async {
  final token = await FirebaseAuth.instance.currentUser?.getIdToken(forceRefresh);
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
  PaintingBinding.instance.imageCache.maximumSize=180;
  PaintingBinding.instance.imageCache.maximumSizeBytes=64*1024*1024;
  meowAppLinks=AppLinks();
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
).copyWith(surface:bg,onSurface:const Color(0xFFEEEEF2),surfaceContainer:panel,surfaceContainerHigh:meowComposerColor,primary:const Color(0xFFB89AFB),outline:const Color(0xFF55555E)), appBarTheme:const AppBarTheme(backgroundColor:panel), inputDecorationTheme:InputDecorationTheme(filled:true,
    fillColor:meowComposerColor, border:OutlineInputBorder(borderRadius:BorderRadius.circular(14))
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
    final uid=widget.uid;
    final ref=db.collection('users').doc(uid);
    final existing=await ref.get().timeout(const Duration(seconds:15));
    if(!(existing.exists&&meowSerial(existing.data()).isNotEmpty&&!(existing.data()??{}).containsKey('username'))){
      await meowAccountAction({'action':'ensure'});
      final updated=await ref.get(const GetOptions(source:Source.server)).timeout(const Duration(seconds:15));
      if(!updated.exists||meowSerial(updated.data()).isEmpty||(updated.data()??{}).containsKey('username'))throw Exception('Cadastro público ainda não migrado.');
    }
    final draft=_meowSignup;
    if(draft==null||privateLoginName(uid)!=draft.login)return;
    if(FirebaseAuth.instance.currentUser?.uid!=uid)throw Exception('Sessão alterada.');
    await ref.update({'displayName':draft.displayName}).timeout(const Duration(seconds:20));
    if(draft.bytes!=null){
      final headers=await authHeaders();
      if(FirebaseAuth.instance.currentUser?.uid!=uid)throw Exception('Sessão alterada.');
      final response=await http.put(mediaUrl('profile',uid,'avatar'),headers:{...headers,'Content-Type':draft.mime!},body:draft.bytes!).timeout(const Duration(seconds:90));
      if(response.statusCode!=200)throw Exception('Não foi possível enviar sua foto (HTTP ${response.statusCode}).');
      PrivateMediaCache.invalidate(mediaUrl('profile',uid,'avatar'));
    }
    if(identical(_meowSignup,draft))_meowSignup=null;
  }

  @override Widget build(BuildContext c)=>FutureBuilder<void>(future:ready,builder:(c,s){
    if(s.connectionState!=ConnectionState.done)return const LoadingCat();
    if(!s.hasError)return const SocialHome();
    return Scaffold(body:Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(
      mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.cloud_off,size:48),
      const SizedBox(height:12),const Text('Não foi possível preparar seu ID Meow.',textAlign:TextAlign.center),
      const Text('Sua conta continua existente. Verifique a conexão e tente novamente.',textAlign:TextAlign.center),
       if(_meowSignup?.bytes!=null)TextButton(onPressed:(){_meowSignup?.bytes=null;setState(()=>ready=prepare());},child:const Text('Continuar sem foto')), 
      const SizedBox(height:12),FilledButton(onPressed:()=>setState(()=>ready=prepare()),child:const Text('Tentar novamente')),
      TextButton(onPressed:()async{_meowSignup=null;PrivateMediaCache.clear();await PrivateMediaCache.purgeDisk();MeowStreams.clear();await FirebaseAuth.instance.signOut();PrivateMediaCache.clear();await PrivateMediaCache.purgeDisk();},child:const Text('Sair da conta'))
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

class _MeowSignupDraft {
 final String login,displayName; Uint8List? bytes; final String? mime;
 _MeowSignupDraft(this.login,this.displayName,this.bytes,this.mime);
}
_MeowSignupDraft? _meowSignup;
class LoginPage extends StatefulWidget {
 const LoginPage({super.key});
 @override State<LoginPage> createState()=>_LoginPageState();
}
class _LoginPageState extends State<LoginPage> {
 final name=TextEditingController(),display=TextEditingController(),password=TextEditingController(),confirm=TextEditingController();
 int step=0; // Welcome, login, signup identity, signup password.
 bool busy=false,hide=true,hideConfirm=true;
 Uint8List? photo;String? mime;String? error;
 @override void dispose(){name.dispose();display.dispose();password.dispose();confirm.dispose();super.dispose();}
 void go(int next){if(busy)return;FocusManager.instance.primaryFocus?.unfocus();setState((){step=next;error=null;hide=true;hideConfirm=true;});}
 void back(){if(step==3){go(2);}else{go(0);}}
 bool validLogin()=>RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(cleanName(name.text));
 void next(){if(display.text.trim().isEmpty||display.text.trim().length>15){setState(()=>error='Informe um nome de exibição de até 15 caracteres.');return;}if(!validLogin()){setState(()=>error='Usuário: 3 a 20 letras, números ou _.');return;}go(3);}
 Future<void> choosePhoto()async{
  if(busy)return;
  setState(()=>busy=true);
  try{
   final source=await showModalBottomSheet<String>(context:context,builder:(c)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[ListTile(leading:const Icon(Icons.photo_library),title:const Text('Galeria'),onTap:()=>Navigator.pop(c,'gallery')),ListTile(leading:const Icon(Icons.folder),title:const Text('Arquivos / GIF original'),onTap:()=>Navigator.pop(c,'file'))])));
   if(!mounted||source==null)return;
   final file=source=='gallery'?await ImagePicker().pickImage(source:ImageSource.gallery,requestFullMetadata:false):await files.openFile(acceptedTypeGroups:const [files.XTypeGroup(label:'Imagens',extensions:['png','jpg','jpeg','webp','gif'])]);
   if(file==null||!mounted)return;
   final type=const {'png':'image/png','jpg':'image/jpeg','jpeg':'image/jpeg','webp':'image/webp','gif':'image/gif'}[file.name.split('.').last.toLowerCase()];
   if(type==null||await file.length()>avatarLimit)throw Exception('Escolha PNG, JPG, WebP ou GIF de até ${fileSizeLabel(avatarLimit)}.');
   final bytes=await file.readAsBytes();if(bytes.isEmpty||bytes.length>avatarLimit)throw Exception('Imagem inválida.');
   final codec=await ui.instantiateImageCodec(bytes);codec.dispose();
   if(mounted)setState((){photo=bytes;mime=type;error=null;});
  }catch(e){if(mounted)setState(()=>error=e.toString().replaceFirst('Exception: ',''));}finally{if(mounted)setState(()=>busy=false);}
 }
 Future<void> submit()async{
  if(busy)return;
  final signup=step==3;
  if(!validLogin()){setState(()=>error='Usuário: 3 a 20 letras, números ou _.');return;}
  if(password.text.length<8){setState(()=>error='A senha precisa de pelo menos 8 caracteres.');return;}
  if(signup&&password.text!=confirm.text){setState(()=>error='As senhas não coincidem.');return;}
  if(signup&&(display.text.trim().isEmpty||display.text.trim().length>15)){go(2);return;}
  final login=cleanName(name.text); final draft=signup?_MeowSignupDraft(login,display.text.trim(),photo,mime):null;
  setState((){busy=true;error=null;});
  _meowSignup=draft;
  try{
   if(signup){await FirebaseAuth.instance.createUserWithEmailAndPassword(email:loginEmail(login),password:password.text);}
   else{await FirebaseAuth.instance.signInWithEmailAndPassword(email:loginEmail(login),password:password.text);}
  }on FirebaseAuthException catch(e){
   if(identical(_meowSignup,draft))_meowSignup=null;
   if(mounted)setState((){if(signup&&e.code=='email-already-in-use'){step=2;error='Este nome de usuário não está disponível.';}else{error=switch(e.code){'wrong-password'||'invalid-credential'||'user-not-found'=>'Usuário ou senha inválidos.','weak-password'=>'Escolha uma senha mais forte.','too-many-requests'=>'Muitas tentativas. Tente mais tarde.','network-request-failed'=>'Verifique sua conexão.',_=>'Não foi possível acessar a conta. (${e.code})'};}});
  }catch(_){if(identical(_meowSignup,draft))_meowSignup=null;if(mounted)setState(()=>error='Não foi possível acessar a conta. Tente novamente.');}
  finally{if(mounted)setState(()=>busy=false);}
 }
 Widget passwordField(TextEditingController controller,String label,bool hidden,VoidCallback toggle)=>TextField(controller:controller,enabled:!busy,obscureText:hidden,autocorrect:false,enableSuggestions:false,decoration:InputDecoration(labelText:label,prefixIcon:const Icon(Icons.lock_outline),suffixIcon:IconButton(onPressed:toggle,icon:Icon(hidden?Icons.visibility_outlined:Icons.visibility_off_outlined))));
 Widget loginField()=>TextField(controller:name,enabled:!busy,autocorrect:false,enableSuggestions:false,maxLength:20,decoration:const InputDecoration(labelText:'Nome de usuário',prefixIcon:Icon(Icons.person_outline),counterText:''));
 @override Widget build(BuildContext c)=>PopScope(canPop:step==0&&!busy,onPopInvokedWithResult:(didPop,_) {if(!didPop&&!busy)back();},child:Scaffold(
  appBar:step==0?null:AppBar(automaticallyImplyLeading:false,leading:IconButton(onPressed:busy?null:back,icon:const Icon(Icons.arrow_back)),title:Text(step==1?'Entrar':step==2?'Etapa 1 de 2':'Etapa 2 de 2')),
  body:SafeArea(child:Center(child:SingleChildScrollView(padding:const EdgeInsets.all(24),child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:420),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,mainAxisSize:MainAxisSize.min,children:[
   if(step==0||step==1)...[const Center(child:Image(image:AssetImage('assets/meow_foreground.png'),width:110,height:110)),const SizedBox(height:16),Text(step==0?'MEOW SOCIAL':'Bem-vindo de volta!',textAlign:TextAlign.center,style:const TextStyle(fontSize:27,fontWeight:FontWeight.bold)),const SizedBox(height:12)],
   if(step==0)...[const Text('Converse. Conecte-se. Personalize.',textAlign:TextAlign.center,style:TextStyle(color:Colors.white70)),const SizedBox(height:44),const Text('Seu espaço, seus amigos.',textAlign:TextAlign.center,style:TextStyle(fontSize:19)),const SizedBox(height:24),FilledButton(onPressed:()=>go(2),child:const Text('Criar conta')),OutlinedButton(onPressed:()=>go(1),child:const Text('Já tenho uma conta'))],
   if(step==1)...[const SizedBox(height:12),loginField(),const SizedBox(height:12),passwordField(password,'Senha',hide,()=>setState(()=>hide=!hide)),const SizedBox(height:18),FilledButton(onPressed:busy?null:submit,child:const Text('Entrar')),TextButton(onPressed:busy?null:()=>go(2),child:const Text('Criar uma conta'))],
   if(step==2)...[const Text('Boas-vindas à Meow!',textAlign:TextAlign.center,style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),const SizedBox(height:8),const Text('Personalize sua identidade.',textAlign:TextAlign.center),const SizedBox(height:20),Center(child:InkWell(onTap:busy?null:choosePhoto,customBorder:const CircleBorder(),child:Container(width:104,height:104,decoration:BoxDecoration(shape:BoxShape.circle,border:Border.all(color:purple,width:2)),child:ClipOval(child:photo==null?const Column(mainAxisAlignment:MainAxisAlignment.center,children:[Icon(Icons.camera_alt_outlined,color:purple,size:32),Text('Adicionar foto',style:TextStyle(fontSize:11))]):Image.memory(photo!,fit:BoxFit.cover,gaplessPlayback:true))))),if(photo!=null)TextButton(onPressed:busy?null:()=>setState((){photo=null;mime=null;}),child:const Text('Remover foto')),const SizedBox(height:20),TextField(controller:display,enabled:!busy,maxLength:15,decoration:const InputDecoration(labelText:'Nome de exibição')),const SizedBox(height:8),loginField(),const SizedBox(height:6),const Text('O nome de login é privado. Sua disponibilidade será verificada ao criar a conta.',style:TextStyle(fontSize:12,color:Colors.white54)),const SizedBox(height:12),FilledButton(onPressed:busy?null:next,child:const Text('Continuar'))],
   if(step==3)...[const Text('Crie sua senha',textAlign:TextAlign.center,style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),const SizedBox(height:18),passwordField(password,'Senha (mínimo 8 caracteres)',hide,()=>setState(()=>hide=!hide)),const SizedBox(height:12),passwordField(confirm,'Confirmar senha',hideConfirm,()=>setState(()=>hideConfirm=!hideConfirm)),const SizedBox(height:18),FilledButton(onPressed:busy?null:submit,child:const Text('Criar conta'))],
   if(busy)const Padding(padding:EdgeInsets.symmetric(vertical:12),child:LinearProgressIndicator()),if(error!=null)Padding(padding:const EdgeInsets.only(top:12),child:Text(error!,style:const TextStyle(color:Colors.redAccent),textAlign:TextAlign.center)),
  ])))))));
}

// Decode static previews close to the display size. Keep animated GIF/WebP
// and full-size image viewers on the original decoder path.
int meowPreviewPixels(double logical,double dpr){
  if(!logical.isFinite||logical<=0)return 0;
  final target=(logical*dpr.clamp(1.0,4.0)).ceil();
  for(final n in const [64,128,256,512,768,1024,1536]){if(target<=n)return n;}
  return 1536;
}
bool meowStaticPreview(Uint8List bytes)=>bytes.length>=8&&((bytes[0]==0xff&&bytes[1]==0xd8)||(bytes[0]==0x89&&bytes[1]==0x50&&bytes[2]==0x4e&&bytes[3]==0x47&&!_meowAnimatedPng(bytes)));
bool _meowAnimatedPng(Uint8List bytes){
  // APNG declares acTL before the first IDAT. Never change animated decoding.
  final data=ByteData.sublistView(bytes);var offset=8;
  while(offset+12<=bytes.length){final n=data.getUint32(offset);final type=data.getUint32(offset+4);if(type==0x6163544c)return true;if(type==0x49444154||type==0x49454e44)return false;if(n>bytes.length-offset-12)return false;offset+=n+12;}return false;
}
Widget meowPreview(BuildContext context,Uint8List bytes,{required double width,required double height,required BoxFit fit,ImageErrorWidgetBuilder? errorBuilder,bool gapless=true}){
  return LayoutBuilder(builder:(c,b){
    final w=b.hasBoundedWidth?b.maxWidth:width;final h=b.hasBoundedHeight?b.maxHeight:height;
    final dpr=MediaQuery.devicePixelRatioOf(c);final px=meowPreviewPixels(w,dpr),py=meowPreviewPixels(h,dpr);
    final ImageProvider provider=meowStaticPreview(bytes)&&px>0&&py>0?ResizeImage(MemoryImage(bytes),width:px,height:py,policy:ResizeImagePolicy.fit):MemoryImage(bytes);
    return Image(image:provider,fit:fit,gaplessPlayback:gapless,errorBuilder:errorBuilder);
  });
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

class _PrivateImageState extends State<PrivateImage>{
  Future<Uint8List?>? future;
  StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? revisionSub;
  String revision='';int revisionEpoch=0;bool revisionKnown=false,profileExists=false;
  Timer? retryTimer;int fetchEpoch=0;Uint8List? lastImage;String? lastOwner;
  bool visible=true;
  void cancelRetry(){retryTimer?.cancel();retryTimer=null;}
  void scheduleRetry(Uri url){cancelRetry();final delay=PrivateMediaCache.retryDelay(url);if(delay==null||!visible)return;retryTimer=Timer(delay,(){if(mounted&&visible&&revisionUrl==url){final lifecycle=WidgetsBinding.instance.lifecycleState;if(lifecycle!=null&&lifecycle!=AppLifecycleState.resumed){retryTimer=Timer(const Duration(seconds:30),(){if(mounted)scheduleRetry(url);});return;}setState(()=>future=fetch());}});}
  Uri get revisionUrl=>revision.isEmpty?widget.url:widget.url.replace(queryParameters:{...widget.url.queryParameters,'revision':revision});
  Future<Uint8List?> fetch()async{
    cancelRetry();final url=revisionUrl;final epoch=++fetchEpoch;final owner=FirebaseAuth.instance.currentUser?.uid;
    if(lastOwner!=owner){lastImage=null;lastOwner=owner;}
    final data=await PrivateMediaCache.get(url);
    if(!mounted||epoch!=fetchEpoch||owner!=FirebaseAuth.instance.currentUser?.uid)return null;
    final retry=PrivateMediaCache.retryDelay(url);
    if(data!=null)lastImage=data;else if(retry==null)lastImage=null;
    scheduleRetry(url);return data??(retry!=null?lastImage:null);
  }
  void watchRevision(){
    if(widget.scope!='profile'||!TickerMode.of(context)){if(revisionSub!=null){revisionEpoch++;revisionSub?.cancel();revisionSub=null;}return;}
    if(revisionSub!=null)return;final epoch=++revisionEpoch;
    revisionSub=db.collection('users').doc(widget.id).meowSnapshots().listen((snap){
      if(!mounted||epoch!=revisionEpoch)return;
      if(!snap.exists&&snap.metadata.isFromCache)return;
      final next=snap.data()?['${widget.slot}Revision']?.toString()??'';
      if(!revisionKnown||next!=revision||snap.exists!=profileExists){setState((){revisionKnown=true;profileExists=snap.exists;revision=next;if(snap.exists){future=fetch();}else{cancelRetry();fetchEpoch++;lastImage=null;future=Future<Uint8List?>.value(null);}});}
    },onError:(Object _){if(mounted&&epoch==revisionEpoch&&!revisionKnown&&future==null)setState(()=>future=fetch());});
  }
  @override void didChangeDependencies(){super.didChangeDependencies();visible=TickerMode.of(context);if(!visible){cancelRetry();}watchRevision();if(visible&&future!=null&&PrivateMediaCache.retryDelay(revisionUrl)!=null)scheduleRetry(revisionUrl);}
  void refresh(){if(mounted&&changedImage.value==widget.url&&(widget.scope!='profile'||revisionKnown))setState(()=>future=fetch());}
  @override void initState(){super.initState();if(widget.scope!='profile')future=fetch();changedImage.addListener(refresh);}
  @override void didUpdateWidget(covariant PrivateImage old){super.didUpdateWidget(old);if(old.url!=widget.url){cancelRetry();fetchEpoch++;lastImage=null;lastOwner=null;revisionEpoch++;revisionSub?.cancel();revisionSub=null;revision='';revisionKnown=false;profileExists=false;future=widget.scope=='profile'?null:fetch();watchRevision();}}
  @override void dispose(){cancelRetry();fetchEpoch++;revisionEpoch++;revisionSub?.cancel();changedImage.removeListener(refresh);super.dispose();}
  @override Widget build(BuildContext c){
    final banner=widget.slot=='banner';final statusIcon=widget.slot.startsWith('status');
    return SizedBox(width:widget.width??(banner?double.infinity:widget.size),height:widget.size,child:ClipRRect(borderRadius:widget.borderRadius??BorderRadius.circular(banner?8:widget.size),child:FutureBuilder<Uint8List?>(key:ValueKey(widget.url),future:future,builder:(c,s){
      final placeholder=ColoredBox(color:panel,child:Center(child:Icon(banner?Icons.landscape:widget.scope=='server'?Icons.groups:Icons.person,color:Colors.white54,size:banner?38:widget.size*.5)));
      return s.data==null?placeholder:meowPreview(c,s.data!,width:widget.width??widget.size,height:widget.size,fit:statusIcon?BoxFit.contain:BoxFit.cover,errorBuilder:(c,e,st){MeowQuietLog.warning('image-decode','Meow: falha ao decodificar imagem.');return placeholder;});
    })));
  }
}

class ChangeImage extends StatefulWidget {
  final String scope,
  id,
  slot,
  label;
  final bool iconOnly;
  final ValueChanged<MeowDraftImage>? onDraft;
  const ChangeImage(this.scope, this.id, this.slot, this.label, {
    super.key,
    this.iconOnly=false,this.onDraft
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
      if(await f.length()>limit)throw Exception('Limite de ${fileSizeLabel(limit)}.');
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
        final result=await Navigator.push<Uint8List>(context,MaterialPageRoute(builder:(_)=>MeowCropPage(bytes:bytes,aspect:widget.slot=='avatar'?1.0:widget.slot=='banner'?(widget.scope=='profile'?meowProfileBannerAspect:3.0):0.75,circle:widget.slot=='avatar',showAvatarGuide:widget.scope=='profile'&&widget.slot=='banner')));
        if(result==null||!mounted)return;
        if(!identical(result,bytes))mime='image/png';
        bytes=result;
      }
      if(bytes.length>limit)throw Exception('Imagem acima do limite após edição.');
      if(widget.onDraft!=null){widget.onDraft!(MeowDraftImage(bytes,mime));return;}
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
    final remaining=t.toDate().add(meowPresenceExpiry+const Duration(milliseconds:50)).difference(DateTime.now());
    if(remaining>Duration.zero)timer=Timer(remaining,(){if(mounted)setState((){});});
  }
  @override void didChangeDependencies(){super.didChangeDependencies();schedule();}
  @override void didUpdateWidget(covariant _PresenceGlyph old){super.didUpdateWidget(old);if(old.data?['lastSeen']!=widget.data?['lastSeen']||old.data?['presence']!=widget.data?['presence']||old.data?['presenceClosedAt']!=widget.data?['presenceClosedAt'])schedule();}
  @override void dispose(){timer?.cancel();super.dispose();}
  @override Widget build(BuildContext c)=>Container(width:17,height:17,decoration:BoxDecoration(color:presenceColor(currentPresence(widget.data)),shape:BoxShape.circle,border:Border.all(color:bg,width:2)));
}
class ProfileAvatar extends StatelessWidget {
  final String uid;
  final double size;
  final bool showPresence;
  const ProfileAvatar({
    super.key,
    required this.uid,
    this.size=40,
    this.showPresence=true
}
);
    @override Widget build(BuildContext c)=>InkWell(onTap:()=>openProfile(c, uid), child:Stack(clipBehavior:Clip.none,
      children:[PrivateImage(scope:'profile', id:uid, slot:'avatar', size:size), if(showPresence) Positioned(right:0, bottom:0,
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
          leading: ProfileAvatar(uid:d.id), title: UserDisplayName(uid:d.id),dense:false,visualDensity:VisualDensity.standard,contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:5),
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
    builder:(context,s)=>SizedBox(height:44,child:FilledButton(
      onPressed:!s.hasData?null:()=>toggleFollow(target,s.data?.exists==true).catchError((Object e){if(context.mounted)notice(context,e);}),
      style:FilledButton.styleFrom(backgroundColor:Theme.of(context).colorScheme.primary,foregroundColor:Theme.of(context).colorScheme.onPrimary,padding:const EdgeInsets.symmetric(horizontal:8)),
      child:FittedBox(fit:BoxFit.scaleDown,child:Text(s.data?.exists==true?'Deixar de seguir':'Seguir',maxLines:1)))));
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
    for(final kind in ['followers','following','friends']) ...[if(kind!='followers')Container(width:1,height:30,color:Theme.of(context).colorScheme.onSurface.withOpacity(.24)),Expanded(child:MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(
      stream:db.collection('users').doc(uid).collection(kind=='friends'?'following':kind).meowSnapshots(),
      builder:(context,s){
        if(kind=='friends')return FutureBuilder<List<String>>(future: MeowMutualChecks.ids(uid,s.data),builder:(context,c)=>_counter(context,kind,c.data?.length??0));
        return _counter(context,kind,s.data?.docs.length??0);
      }))]]);
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
Widget meowBadgeArt(MeowBadgeDefinition badge,{double size=38})=>Image.asset('assets/badges/${badge.id}.png',width:size,height:size,fit:BoxFit.contain);
Set<String> meowBadges(Map<String,dynamic> data){
 final raw=data['badges'];
 return raw is List?raw.whereType<String>().where((id)=>meowBadgeDefinitions.any((b)=>b.id==id)).toSet():<String>{};
}
class MeowProfileBadges extends StatefulWidget {
 final Map<String,dynamic> data;final Color background,ink;
 const MeowProfileBadges({super.key,required this.data,required this.background,required this.ink});
 @override State<MeowProfileBadges> createState()=>_MeowProfileBadgesState();
}
class _MeowProfileBadgesState extends State<MeowProfileBadges> {
 OverlayEntry? entry;Timer? fadeTimer,removeTimer;bool shown=true;
 void dismiss(){fadeTimer?.cancel();removeTimer?.cancel();entry?.remove();entry?.dispose();entry=null;}
 void show(MeowBadgeDefinition badge){
   dismiss();shown=true;
   final overlay=Overlay.of(context,rootOverlay:true);
   entry=OverlayEntry(builder:(c)=>Positioned(top:MediaQuery.viewPaddingOf(c).top+5,left:16,right:16,child:IgnorePointer(child:TweenAnimationBuilder<double>(tween:Tween<double>(begin:0,end:shown?1:0),duration:const Duration(milliseconds:230),curve:Curves.easeOutCubic,builder:(c,value,child)=>Opacity(opacity:value,child:Transform.translate(offset:Offset(0,-12*(1-value)),child:child)),child:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:340),child:Material(color:const Color(0xFF0A0A0E),borderRadius:BorderRadius.circular(30),elevation:8,child:Padding(padding:const EdgeInsets.symmetric(horizontal:15,vertical:11),child:Row(mainAxisSize:MainAxisSize.min,children:[meowBadgeArt(badge,size:36),const SizedBox(width:10),Flexible(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(badge.title,style:const TextStyle(color:Colors.white,fontSize:13,fontWeight:FontWeight.bold)),Text(badge.description,style:const TextStyle(color:Colors.white70,fontSize:11))]))])))))))));
   overlay.insert(entry!);
   fadeTimer=Timer(const Duration(milliseconds:4750),(){shown=false;entry?.markNeedsBuild();});
   removeTimer=Timer(const Duration(seconds:5),dismiss);
 }
 @override void dispose(){dismiss();super.dispose();}
 @override Widget build(BuildContext c){
   final ids=meowBadges(widget.data);if(ids.isEmpty)return const SizedBox.shrink();
   return Center(child:Container(margin:const EdgeInsets.symmetric(vertical:6),padding:const EdgeInsets.symmetric(horizontal:6),decoration:BoxDecoration(color:widget.background,borderRadius:BorderRadius.circular(18)),child:Wrap(alignment:WrapAlignment.center,crossAxisAlignment:WrapCrossAlignment.center,spacing:2,children:[
     for(final badge in meowBadgeDefinitions)if(ids.contains(badge.id))IconButton(tooltip:badge.title,constraints:const BoxConstraints(minWidth:44,minHeight:44),padding:const EdgeInsets.all(2),icon:meowBadgeArt(badge),onPressed:()=>show(badge))
   ])));
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
  }catch(e){if(mounted)notice(context,'Não foi possível alterar as insígnias: $e');}
  finally{if(mounted)setState(()=>busy=false);}
 }
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Gerenciar insígnias')),body:ListView(padding:const EdgeInsets.all(16),children:[
   TextField(controller:search,enabled:!busy,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'ID Meow'),onSubmitted:(_)=>find()),
   const SizedBox(height:8),FilledButton(onPressed:busy?null:find,child:const Text('Buscar conta')),
   if(target!=null)...[const SizedBox(height:12),ListTile(leading:ProfileAvatar(uid:target!.id),title:Text(userLabel(target!.data()??{})),subtitle:Text(meowPublicId(target!.data()))),
    for(final b in meowBadgeDefinitions)CheckboxListTile(secondary:meowBadgeArt(b,size:36),title:Text(b.title),subtitle:Text(b.description),value:selected.contains(b.id),onChanged:busy?null:(v)=>setState((){if(v==true){selected.add(b.id);}else{selected.remove(b.id);}})),
    FilledButton(onPressed:busy?null:save,child:const Text('Salvar alterações'))],
   if(busy)const Padding(padding:EdgeInsets.all(12),child:LinearProgressIndicator())]));
}
// Shared profile banner aspect; used by the profile editor and cropper.
const double meowProfileBannerAspect=2.2;
class MeowStatusBubble extends StatelessWidget {
 final String status;final Color background,ink;final VoidCallback? onTap;final List<Widget> emojis;
 const MeowStatusBubble({super.key,required this.status,required this.background,required this.ink,this.onTap,this.emojis=const []});
 @override Widget build(BuildContext c)=>Stack(clipBehavior:Clip.none,children:[
   Positioned(left:0,top:-9,child:Container(width:8,height:8,decoration:BoxDecoration(color:background,shape:BoxShape.circle))),
   Positioned(left:12,top:-6,child:Container(width:15,height:15,decoration:BoxDecoration(color:background,shape:BoxShape.circle))),
   Material(color:background,borderRadius:BorderRadius.circular(14),child:InkWell(onTap:onTap,borderRadius:BorderRadius.circular(14),child:Padding(padding:const EdgeInsets.symmetric(horizontal:8,vertical:6),child:Wrap(spacing:4,runSpacing:2,crossAxisAlignment:WrapCrossAlignment.center,children:[if(status.isNotEmpty)Text(status,maxLines:3,overflow:TextOverflow.ellipsis,style:TextStyle(color:ink,fontSize:MeowMessageText.isEmojiOnly(status)?32:12)),...emojis])))),
 ]);
}
const meowStatusSlots=['status0','status1','status2','status3'];
List<Widget> meowStatusIcons(String uid,Map<String,dynamic> data,Map<String,MeowDraftImage> draftImages)=>[
 for(final slot in meowStatusSlots)if(draftImages.containsKey(slot))Image.memory(draftImages[slot]!.bytes,width:32,height:32,fit:BoxFit.contain,gaplessPlayback:true)
 else if((data['${slot}Revision']?.toString()??'').isNotEmpty)PrivateImage(scope:'profile',id:uid,slot:slot,size:32,borderRadius:BorderRadius.zero),
];
class ProfilePage extends StatelessWidget {
  final String uid; final bool expanded; final ScrollController? scrollController;
  final Map<String,dynamic>? draft; final Map<String,MeowDraftImage> draftImages;
  const ProfilePage({super.key,required this.uid,this.expanded=false,this.scrollController,this.draft,this.draftImages=const {}});
  Widget media(String slot,double size,{BorderRadius? borderRadius}) { final image=draftImages[slot]; return image==null?PrivateImage(scope:'profile',id:uid,slot:slot,size:size,borderRadius:borderRadius):SizedBox(height:size,width:slot=='avatar'?size:double.infinity,child:ClipRRect(borderRadius:borderRadius??BorderRadius.circular(size),child:Image.memory(image.bytes,fit:BoxFit.cover,gaplessPlayback:true))); }
  @override Widget build(BuildContext c)=>MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(uid).meowSnapshots(),builder:(c,s){
    if(s.hasError||s.hasData&&s.data?.exists!=true)return const Center(child:Text('Perfil indisponível.'));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    final d=draft??s.data!.data()??{}; final own=uid==FirebaseAuth.instance.currentUser?.uid;
    final base=meowColor(d['themeColorA'],panel);final end=d['themeGradient']==true?meowColor(d['themeColorB'],base):base;
    final ink=d['backgroundEnabled']==true?Colors.white:Color.lerp(base,end,.5)!.computeLuminance()>.42?Colors.black:Colors.white;
    final accent=ink.withOpacity(.20);
    final tone=HSLColor.fromColor(Color.lerp(base,end,.5)!);
    final light=ink==Colors.black;
    final neutral=light?const Color(0xFFF0F0F2):const Color(0xFF28282D);
    final softened=tone.withSaturation(min(tone.saturation,.28)).withLightness(light ? .78 : .24).toColor();
    final cardColor=Color.lerp(neutral,softened,.55)!.withOpacity(.88);
    final primary=HSLColor.fromColor(softened).withLightness(light ? .36 : .70).toColor();
    final buttonInk=primary.computeLuminance()>.42?Colors.black:Colors.white;
    final presence=draft==null?currentPresence(d):d['presence']?.toString()??'offline';final status=d['customStatus']?.toString().trim()??'';final statusIcons=meowStatusIcons(uid,d,draftImages);final hasStatus=status.isNotEmpty||statusIcons.isNotEmpty;
    final theme=Theme.of(c);
    return Theme(data:theme.copyWith(textTheme:theme.textTheme.apply(bodyColor:ink,displayColor:ink),colorScheme:theme.colorScheme.copyWith(surface:base,onSurface:ink,primary:primary,onPrimary:buttonInk)),child:Container(decoration:BoxDecoration(gradient:profileGradient(d)),child:Stack(children:[
      if(d['backgroundEnabled']==true)Positioned.fill(child:draftImages['background']==null?ProfileBackground(uid:uid):Stack(fit:StackFit.expand,children:[Image.memory(draftImages['background']!.bytes,fit:BoxFit.cover,gaplessPlayback:true),const ColoredBox(color:Color(0x99000000))])),
      ListView(controller:scrollController,padding:EdgeInsets.zero,children:[
        LayoutBuilder(builder:(c,box){
          final width=box.maxWidth;final hasBanner=d['bannerHidden']!=true;
          final h=hasBanner?width/meowProfileBannerAspect:56.0;
          final avatar=min(96.0,width*.27);final radius=avatar/2+3;
          final space=max(0.0,width/2-radius-18);
          return Column(children:[SizedBox(height:h+radius+8,child:Stack(clipBehavior:Clip.none,children:[
            if(hasBanner)Positioned(left:0,right:0,top:0,height:h,child:media('banner',h,borderRadius:BorderRadius.zero)),
            Positioned(top:8,right:8,child:Material(color:hasBanner?Colors.black54:cardColor,shape:const CircleBorder(),child:PopupMenuButton<String>(tooltip:'Opções do perfil',icon:Icon(Icons.more_horiz,color:hasBanner?Colors.white:ink),onSelected:(action)async{if(action=='id'){await Clipboard.setData(ClipboardData(text:meowSerial(d)));if(c.mounted)notice(c,'ID copiado!');}},itemBuilder:(_)=>[PopupMenuItem(value:'id',enabled:meowSerial(d).isNotEmpty,child:Row(mainAxisSize:MainAxisSize.min,children:[Text(meowPublicId(d)),const SizedBox(width:12),const Icon(Icons.copy,size:16)]))]))),
            Positioned(left:width/2-radius,top:h-radius,child:Container(padding:const EdgeInsets.all(3),decoration:BoxDecoration(color:base,shape:BoxShape.circle),child:Stack(clipBehavior:Clip.none,children:[media('avatar',avatar),Positioned(right:2,bottom:2,child:draft==null?PresenceDot(uid:uid):Container(width:17,height:17,decoration:BoxDecoration(shape:BoxShape.circle,color:presenceColor(d['presence']?.toString()??'offline'),border:Border.all(color:bg,width:2))))]))),
            if(hasStatus&&space>=45)Positioned(left:width/2+radius+9,top:h-radius/2,width:space,child:MeowStatusBubble(status:status,background:Color.lerp(base,ink,.12)!,ink:ink,emojis:statusIcons)),
          ])),
          if(hasStatus&&space<45)Padding(padding:const EdgeInsets.all(6),child:MeowStatusBubble(status:status,background:Color.lerp(base,ink,.12)!,ink:ink,emojis:statusIcons)),
          Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Text(userLabel(d),textAlign:TextAlign.center,maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(fontSize:25,fontWeight:FontWeight.bold,color:ink))),
          if((d['pronouns']?.toString()??'').isNotEmpty)Text(d['pronouns'].toString(),textAlign:TextAlign.center,style:TextStyle(color:ink.withOpacity(.8),fontSize:12)),
          MeowProfileBadges(data:d,background:cardColor,ink:ink),
          Row(mainAxisAlignment:MainAxisAlignment.center,children:[Icon(Icons.circle,size:9,color:presenceColor(presence)),const SizedBox(width:6),Text(presenceLabels[presence]??'Offline',style:TextStyle(color:ink.withOpacity(.75)))]),
          ]);
        }),
        Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Container(decoration:BoxDecoration(color:cardColor,borderRadius:BorderRadius.circular(15),border:Border.all(color:accent)),padding:const EdgeInsets.symmetric(vertical:8),child:RelationshipCounters(uid:uid)),
          const SizedBox(height:12),
          if(own)FilledButton.icon(onPressed:draft!=null?null:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>EditProfilePage(uid:uid))),icon:const Icon(Icons.edit),label:const Text('Editar perfil'))
          else Row(children:[Expanded(child:FollowButton(target:uid)),const SizedBox(width:8),Expanded(child:SizedBox(height:44,child:OutlinedButton(onPressed:()async{if(expanded){Navigator.pop(c,'dm');}else{await openDm(c,uid);}},style:OutlinedButton.styleFrom(foregroundColor:ink,padding:const EdgeInsets.symmetric(horizontal:8),side:BorderSide(color:ink.withOpacity(.65))),child:const FittedBox(fit:BoxFit.scaleDown,child:Text('Enviar mensagem',maxLines:1)))))]),
          const SizedBox(height:8),MeowProfileSections(key:ValueKey(uid),uid:uid,data:d,cardColor:cardColor,ink:ink),
          if(own&&!expanded&&draft==null)TextButton.icon(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const AppSettingsPage())),icon:const Icon(Icons.settings),label:const Text('Configurações do aplicativo')),
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
   Row(children:[for(var i=0;i<3;i++)Expanded(child:TextButton(onPressed:(){setState(()=>section=i);},child:Column(children:[Text(['Sobre','Amigos','Servidores'][i],style:TextStyle(fontWeight:section==i?FontWeight.bold:FontWeight.normal,color:widget.ink)),const SizedBox(height:4),Container(height:2,color:section==i?Theme.of(c).colorScheme.primary:Colors.transparent)])))]),const Divider(height:1),const SizedBox(height:12),
   if(section==0)...[Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:widget.cardColor,borderRadius:BorderRadius.circular(14)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Sobre mim',style:TextStyle(fontWeight:FontWeight.bold)),const SizedBox(height:6),MeowMessageText(text:(widget.data['bio']?.toString()??'').isEmpty?'Sem biografia.':widget.data['bio'].toString(),people:const {})])),const SizedBox(height:16),Text(widget.uid==myUid?'Meus servidores':'Servidores em comum',style:const TextStyle(fontWeight:FontWeight.bold)),MeowCommonServers(uid:widget.uid)]
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
      const MeowPendingDeletions(),
      ListTile(leading:const Icon(Icons.person),title:const Text('Conta'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Conta')),body:ListView(children:[
        ListTile(title:const Text('Nome de usuário (login)'),subtitle:SelectableText(privateLoginName(myUid)),leading:const Icon(Icons.lock_outline)),
        ListTile(title:const Text('Editar perfil'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>EditProfilePage(uid:myUid)))),
        ListTile(title:const Text('Alterar senha'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const ChangePasswordPage()))), ListTile(title:const Text('Sair da conta'),onTap:()=>logoutMeow(c))]))))),
      const MeowAdminEntry(),
      ListTile(leading:const Icon(Icons.notifications),title:const Text('Notificações'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const NotificationSettingsPage()))),
      ListTile(leading:const Icon(Icons.storage),title:const Text('Armazenamento'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const MeowStoragePage()))),
      ListTile(leading:const Icon(Icons.info),title:const Text('Sobre o Meow'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Sobre o Meow')),body:const Center(child:MeowTitle()))))),
    ]));
}
class MeowCacheMaintenance {
 static const key='meow_last_cache_cleanup_091';static bool busy=false;
 static Future<DateTime?> last()async{final p=await SharedPreferences.getInstance();final n=p.getInt(key);return n==null?null:DateTime.fromMillisecondsSinceEpoch(n);}
 static Future<void> maybeClean()async{try{final p=await last();if(p==null||DateTime.now().difference(p)>=const Duration(hours:12))await clean(automatic:true);}catch(e){MeowQuietLog.warning('cache-clean','Meow: falha temporária na limpeza do cache.');}}
 static Future<void> clean({bool automatic=false})async{if(busy)return;busy=true;try{if(automatic){PrivateMediaCache.pruneExpired();await PrivateMediaCache.pruneDisk();}else{PrivateMediaCache.purgeCompleted();await PrivateMediaCache.purgeDisk();}await MeowVideoCache.clear();final prefs=await SharedPreferences.getInstance();await prefs.setInt(key,DateTime.now().millisecondsSinceEpoch);}finally{busy=false;}}
}
class MeowStoragePage extends StatefulWidget{const MeowStoragePage({super.key});@override State<MeowStoragePage> createState()=>_MeowStoragePageState();}
class _MeowStoragePageState extends State<MeowStoragePage>{
 late Future<Map<String,dynamic>> data;bool busy=false;
 @override void initState(){super.initState();data=read();}
 Future<Map<String,dynamic>> read()async{final native=await _nativeNotification<Map<dynamic,dynamic>>('storageStats');final last=await MeowCacheMaintenance.last();return {if(native!=null)...Map<String,dynamic>.from(native),'last':last,'media':(await MeowVideoCache.bytes())+(await PrivateMediaCache.diskBytes())};}
 Future<void> clean()async{if(busy)return;setState(()=>busy=true);try{await MeowCacheMaintenance.clean();if(mounted){setState(()=>data=read());notice(context,'Cache temporário da Meow limpo.');}}catch(e){if(mounted)notice(context,'Não foi possível limpar o cache: $e');}finally{if(mounted)setState(()=>busy=false);}}
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Armazenamento'),actions:[IconButton(tooltip:'Atualizar',onPressed:busy?null:()=>setState(()=>data=read()),icon:const Icon(Icons.refresh))]),body:FutureBuilder<Map<String,dynamic>>(future:data,builder:(c,s){
  if(!s.hasData&&!s.hasError)return const Center(child:CircularProgressIndicator());final d=s.data??{};
  final app=(d['app'] as num?)?.toInt(),user=(d['data'] as num?)?.toInt(),cache=(d['cache'] as num?)?.toInt();final total=app!=null&&user!=null&&cache!=null?app+user+cache:null;
  final values=[app,user,cache];final colors=[purple,Colors.lightBlueAccent,Colors.amber];final names=['Tamanho do aplicativo','Dados do usuário','Cache temporário'];
  return ListView(padding:const EdgeInsets.all(18),children:[const SizedBox(height:12),const Text('Espaço total utilizado',textAlign:TextAlign.center,style:TextStyle(color:Colors.white70)),Text(total==null?'Indisponível':fileSizeLabel(total),textAlign:TextAlign.center,style:const TextStyle(fontSize:32,fontWeight:FontWeight.bold)),const SizedBox(height:20),if(total!=null&&total>0)ClipRRect(borderRadius:BorderRadius.circular(8),child:SizedBox(height:12,child:Row(children:[for(var i=0;i<3;i++)if((values[i]??0)>0)Expanded(flex:max(1,((values[i]??0)/total*1000).round()),child:ColoredBox(color:colors[i]))]))),const SizedBox(height:12),for(var i=0;i<3;i++)ListTile(contentPadding:EdgeInsets.zero,leading:Icon(Icons.circle,color:colors[i],size:12),title:Text(names[i]),trailing:Text(values[i]==null?'Indisponível':fileSizeLabel(values[i]!,preferMB:i==1),style:const TextStyle(fontWeight:FontWeight.w600))),const Divider(),const ListTile(contentPadding:EdgeInsets.zero,title:Text('Limpeza automática'),subtitle:Text('A cada 12 horas em uso, ou na próxima abertura. Remove mídias vencidas sem descartar o cache recente.'),trailing:Icon(Icons.schedule,color:purple)),Text('Última limpeza: ${d['last'] is DateTime?formatMeowTime(d['last'] as DateTime):'Ainda não realizada'}',style:const TextStyle(color:Colors.white54)),const SizedBox(height:16),FilledButton.icon(onPressed:busy?null:clean,icon:const Icon(Icons.delete_outline),label:Text(busy?'Limpando…':'Limpar cache temporário')),const SizedBox(height:8),const Text('A limpeza remove somente mídias temporárias da Meow. Os dados de login, mensagens, downloads e arquivos em uso são preservados.',style:TextStyle(color:Colors.white54,fontSize:12))]);
 }));
}
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});
  @override State<NotificationSettingsPage> createState()=>_NotificationSettingsPageState();
}
class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Notificações')),body:MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(myUid).collection('preferences').doc('notifications').meowSnapshots(),builder:(c,s){
    final d=s.data?.data()??{};final enabled=d['enabled']!=false;
    return ListView(children:[SwitchListTile(title:const Text('Notificações da conta'),value:enabled,onChanged:(v)async{try{await db.collection('users').doc(myUid).collection('preferences').doc('notifications').set({'enabled':v},SetOptions(merge:true));if(v)await FirebaseMessaging.instance.requestPermission();}catch(e){if(c.mounted)notice(c,e);}}),const ListTile(title:Text('Silenciar conversas'),subtitle:Text('Use o sino no cabeçalho de um canal ou DM.')),const ListTile(title:Text('Privacidade'),subtitle:Text('As notificações mostram o remetente e uma prévia. Controle a exibição na tela bloqueada nas configurações do aparelho.'))]);
  }));
}
class MeowDraftImage {
 final Uint8List bytes;final String mime;
 const MeowDraftImage(this.bytes,this.mime);
}
class EditProfilePage extends StatefulWidget {
 final String uid;const EditProfilePage({super.key,required this.uid});
 @override State<EditProfilePage> createState()=>_EditProfilePageState();
}
class _EditProfilePageState extends State<EditProfilePage> {
 final draft=<String,dynamic>{}, original=<String,dynamic>{};
 final images=<String,MeowDraftImage>{};
 bool loaded=false,busy=false,allowExit=false;
 static const keys=['displayName','pronouns','bio','customStatus','presence','themeColorA','themeColorB','themeGradient','bannerHidden','backgroundEnabled','status0Revision','status1Revision','status2Revision','status3Revision'];
 bool get dirty=>images.isNotEmpty||keys.any((k)=>draft[k]!=original[k]);
 void load(Map<String,dynamic> d){
   draft.addAll(d);for(final k in ['displayName','pronouns','bio','customStatus']){draft[k]=d[k]?.toString()??'';}
   draft['presence']=presenceLabels.containsKey(d['presence'])?d['presence']:'online';
   draft['themeColorA']=meowHex(meowColor(d['themeColorA'],panel));draft['themeColorB']=meowHex(meowColor(d['themeColorB'],purple));
   for(final k in ['themeGradient','bannerHidden','backgroundEnabled']){draft[k]=d[k]==true;}
   for(final slot in meowStatusSlots){draft['${slot}Revision']=d['${slot}Revision']?.toString()??'';}original.addAll(draft);loaded=true;
 }
 void change(String k,Object? value){if(!busy&&mounted)setState(()=>draft[k]=value);}
 void mediaChanged(String slot,MeowDraftImage image){if(busy||!mounted)return;setState((){images[slot]=image;if(slot=='banner')draft['bannerHidden']=false;if(slot=='background')draft['backgroundEnabled']=true;});}
 void remove(String slot){if(busy)return;setState((){images.remove(slot);draft[slot=='banner'?'bannerHidden':'backgroundEnabled']=slot=='banner';});}
 Future<void> exit()async{
   if(busy)return;
   if(dirty){final discard=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('Sair sem salvar?'),content:const Text('Todas as alterações não salvas serão descartadas.'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Continuar editando')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Descartar e sair'))]));if(discard!=true||!mounted)return;}
   if(mounted){setState(()=>allowExit=true);WidgetsBinding.instance.addPostFrameCallback((_) {if(mounted)Navigator.pop(context);});}
 }
 Future<void> editText(String key,String label,int limit,{int lines=1})async{
   if(busy)return;
   final controller=TextEditingController(text:draft[key]?.toString()??'');
   final value=await showDialog<String>(context:context,builder:(c)=>AlertDialog(title:Text(label),content:TextField(controller:controller,autofocus:true,maxLength:limit,maxLines:lines),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Cancelar')),FilledButton(onPressed:()=>Navigator.pop(c,controller.text),child:const Text('Aplicar'))]));
   // Dispose after the closing route has released the controller.
   Future<void>.delayed(const Duration(milliseconds:350),controller.dispose);
   if(value!=null&&mounted)change(key,value);
 }
 Future<void> editStatus()async{
   if(busy)return;
   final text=TextEditingController(text:draft['customStatus']?.toString()??'');
   final local=<String,MeowDraftImage>{for(final slot in meowStatusSlots)if(images.containsKey(slot))slot:images[slot]!};
   final refs=<String,String>{for(final slot in meowStatusSlots)slot:draft['${slot}Revision']?.toString()??''};
   bool picking=false;
   final applied=await showDialog<bool>(context:context,builder:(dialog)=>StatefulBuilder(builder:(c,update)=>AlertDialog(title:const Text('Status personalizado'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
     TextField(controller:text,maxLength:100,maxLines:2,decoration:const InputDecoration(hintText:'Escreva seu status')),
     Wrap(spacing:5,children:[for(final slot in meowStatusSlots)if(local.containsKey(slot)||refs[slot]!.isNotEmpty)InputChip(label:local.containsKey(slot)?Image.memory(local[slot]!.bytes,width:22,height:22,fit:BoxFit.contain):PrivateImage(scope:'profile',id:widget.uid,slot:slot,size:22,borderRadius:BorderRadius.zero),onDeleted:picking?null:()=>update((){local.remove(slot);refs[slot]='';}))]),
     OutlinedButton.icon(onPressed:picking?null:()async{
       update(()=>picking=true);
       try{final selected=await pickExpression(c,reactionOnly:true);if(!c.mounted||selected==null)return;
         if(selected is String){final next=text.text+selected;if(next.characters.length<=100){text.text=next;text.selection=TextSelection.collapsed(offset:next.length);}}
         else if(selected is Map<String,dynamic>){final available=meowStatusSlots.where((slot)=>!local.containsKey(slot)&&refs[slot]!.isEmpty);if(available.isEmpty){notice(context,'Até quatro emojis personalizados no status.');return;}final bytes=await PrivateMediaCache.get(expressionUrl(selected));if(bytes==null||bytes.length>5000000)throw Exception('Emoji indisponível.');if(c.mounted)update(()=>local[available.first]=MeowDraftImage(bytes,'application/octet-stream'));}
       }catch(e){if(mounted)notice(context,e);}finally{if(c.mounted)update(()=>picking=false);}
     },icon:const Icon(Icons.emoji_emotions_outlined),label:const Text('Adicionar emoji')),
     if(picking)const LinearProgressIndicator(),
   ])),actions:[TextButton(onPressed:picking?null:()=>Navigator.pop(c,false),child:const Text('Cancelar')),TextButton(onPressed:picking?null:(){text.clear();local.clear();for(final slot in meowStatusSlots){refs[slot]='';}Navigator.pop(c,true);},child:const Text('Remover status')),FilledButton(onPressed:picking?null:()=>Navigator.pop(c,true),child:const Text('Aplicar'))])));
   final value=text.text;Future<void>.delayed(const Duration(milliseconds:350),text.dispose);
   if(applied==true&&mounted)setState((){draft['customStatus']=value;for(final slot in meowStatusSlots){draft['${slot}Revision']=refs[slot];images.remove(slot);if(local.containsKey(slot))images[slot]=local[slot]!;}});
 }
 Future<void> color(String key)async{if(busy)return;final value=await showDialog<Color>(context:context,builder:(_)=>MeowColorWheelDialog(initial:meowColor(draft[key],panel)));if(value!=null)change(key,meowHex(value));}
 Future<void> save()async{
   if(busy||!dirty||!loaded)return;
   if((draft['displayName'] as String).trim().isEmpty){notice(context,'Informe um nome de exibição.');return;}
   if(FirebaseAuth.instance.currentUser?.uid!=widget.uid)return;
   setState(()=>busy=true);
   try{
     final updates=<String,dynamic>{for(final k in keys)if(draft[k]!=original[k])k:draft[k]};
     final random=Random.secure();final rev=List.generate(32,(_)=>random.nextInt(16).toRadixString(16)).join();
     for(final entry in images.entries){
       final uri=mediaUrl('profile',widget.uid,entry.key);final staged=uri.replace(queryParameters:{...uri.queryParameters,'stage':rev});
       final response=await http.put(staged,headers:{...await authHeaders(),'Content-Type':entry.value.mime},body:entry.value.bytes).timeout(const Duration(seconds:120));
       if(response.statusCode!=201)throw Exception('Não foi possível preparar ${entry.key} (HTTP ${response.statusCode}).');
       updates['${entry.key}Revision']=rev;
     }
     if(FirebaseAuth.instance.currentUser?.uid!=widget.uid)throw Exception('Sessão alterada.');
     final ref=db.collection('users').doc(widget.uid);
     // Firestore transactions require a connection and publish one atomic update.
     await db.runTransaction((tx)async{final current=await tx.get(ref);if(!current.exists)throw Exception('Perfil indisponível.');if(FirebaseAuth.instance.currentUser?.uid!=widget.uid)throw Exception('Sessão alterada.');if(updates.isNotEmpty)tx.update(ref,updates);});
     for(final slot in images.keys){final url=mediaUrl('profile',widget.uid,slot);PrivateMediaCache.invalidate(url);changedImage.value=null;changedImage.value=url;}
     if(mounted){notice(context,'Perfil salvo!');setState((){busy=false;allowExit=true;});WidgetsBinding.instance.addPostFrameCallback((_) {if(mounted)Navigator.pop(context);});}
   }catch(e){if(mounted){notice(context,'Não foi possível salvar: $e');setState(()=>busy=false);}}
 }
 Widget media(String slot,double size){final item=images[slot];return item==null?PrivateImage(scope:'profile',id:widget.uid,slot:slot,size:size,borderRadius:slot=='banner'?BorderRadius.circular(12):null):SizedBox(width:slot=='avatar'?size:double.infinity,height:size,child:ClipRRect(borderRadius:BorderRadius.circular(slot=='avatar'?size:12),child:Image.memory(item.bytes,fit:BoxFit.cover,gaplessPlayback:true)));}
 Widget editIcon(String slot)=>ChangeImage('profile',widget.uid,slot,'Editar $slot',iconOnly:true,onDraft:(image)=>mediaChanged(slot,image));
 Widget field(String key,String label,IconData icon,int limit,{int lines=1})=>ListTile(dense:true,leading:Icon(icon),title:Text(label),subtitle:Text((draft[key]?.toString()??'').isEmpty?'Não definido':draft[key].toString(),maxLines:1,overflow:TextOverflow.ellipsis),trailing:const Icon(Icons.chevron_right),onTap:busy?null:()=>editText(key,label,limit,lines:lines));
 Widget colorRow(String key,String label)=>ListTile(dense:true,title:Text(label),trailing:Container(width:32,height:32,decoration:BoxDecoration(color:meowColor(draft[key],panel),borderRadius:BorderRadius.circular(8),border:Border.all(color:Colors.white30))),onTap:busy?null:()=>color(key));
 @override Widget build(BuildContext c)=>PopScope(canPop:allowExit,onPopInvokedWithResult:(didPop,_) {if(!didPop)exit();},child:Scaffold(appBar:AppBar(automaticallyImplyLeading:false,leading:IconButton(icon:const Icon(Icons.arrow_back),onPressed:busy?null:exit),title:const Text('Editar perfil'),actions:[TextButton(onPressed:busy||!dirty?null:save,child:Text(busy?'Salvando…':'Salvar'))]),body:MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(widget.uid).meowSnapshots(),builder:(c,s){
   if(!loaded){if(s.hasError)return const Center(child:Text('Perfil indisponível.'));if(!s.hasData)return const Center(child:CircularProgressIndicator());load(s.data!.data()??{});}
   return Column(children:[if(busy)const LinearProgressIndicator(),Expanded(child:AbsorbPointer(absorbing:busy,child:ListView(padding:const EdgeInsets.all(14),children:[
     LayoutBuilder(builder:(c,b){final w=b.maxWidth;final h=w/meowProfileBannerAspect;final avatar=min(90.0,w*.26);return SizedBox(height:h+avatar/2+8,child:Stack(clipBehavior:Clip.none,children:[
       Positioned(left:0,right:0,top:0,height:h,child:draft['bannerHidden']==true?DecoratedBox(decoration:BoxDecoration(gradient:profileGradient(draft),borderRadius:BorderRadius.circular(12))):media('banner',h)),
       Positioned(top:6,right:6,child:Row(children:[if(draft['bannerHidden']!=true)IconButton.filledTonal(tooltip:'Remover banner',onPressed:()=>remove('banner'),icon:const Icon(Icons.hide_image)),editIcon('banner')])),
       Positioned(left:(w-avatar)/2,top:h-avatar/2,child:Stack(clipBehavior:Clip.none,children:[media('avatar',avatar),Positioned(top:-4,right:-6,child:editIcon('avatar'))])),
       Positioned(left:w/2+avatar/2+6,right:0,top:h-avatar/4,child:MeowStatusBubble(status:(draft['customStatus'] as String).isEmpty&&meowStatusIcons(widget.uid,draft,images).isEmpty?'+ Status':draft['customStatus'].toString(),background:panel,ink:Colors.white,onTap:editStatus,emojis:meowStatusIcons(widget.uid,draft,images))),
     ]));}),
     Text(userLabel(draft),textAlign:TextAlign.center,style:const TextStyle(fontSize:24,fontWeight:FontWeight.bold)),Text(draft['pronouns']?.toString()??'',textAlign:TextAlign.center),
     const SizedBox(height:12),Card(color:panel,child:Column(children:[field('displayName','Nome de exibição',Icons.person_outline,15),const Divider(height:1),field('pronouns','Pronomes',Icons.format_quote,40),const Divider(height:1),field('bio','Biografia',Icons.notes,300,lines:4),const Divider(height:1),ListTile(dense:true,title:const Text('Disponibilidade'),trailing:DropdownButton<String>(value:draft['presence'] as String,items:presenceLabels.entries.map((e)=>DropdownMenuItem(value:e.key,child:Text(e.value))).toList(),onChanged:(v){if(v!=null)change('presence',v);}))])),
     const SizedBox(height:10),const Text('Aparência do perfil',style:TextStyle(fontWeight:FontWeight.bold,fontSize:17)),const SizedBox(height:8),
     Card(color:panel,child:Column(children:[Container(height:85,margin:const EdgeInsets.all(12),clipBehavior:Clip.antiAlias,decoration:BoxDecoration(gradient:profileGradient(draft),borderRadius:BorderRadius.circular(12)),child:draft['backgroundEnabled']==true?(images['background']!=null?Image.memory(images['background']!.bytes,width:double.infinity,fit:BoxFit.cover,gaplessPlayback:true):ProfileBackground(uid:widget.uid)):const SizedBox.expand()),
       SwitchListTile(title:const Text('Usar gradiente'),value:draft['themeGradient']==true,onChanged:(v)=>change('themeGradient',v)),colorRow('themeColorA','Cor principal'),if(draft['themeGradient']==true)colorRow('themeColorB','Cor secundária'),
       ChangeImage('profile',widget.uid,'background','Escolher foto ou GIF de fundo',onDraft:(image)=>mediaChanged('background',image)),if(draft['backgroundEnabled']==true)TextButton(onPressed:()=>remove('background'),child:const Text('Remover imagem de fundo'))])),
     const SizedBox(height:12),OutlinedButton.icon(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Prévia do perfil')),body:ProfilePage(uid:widget.uid,draft:Map.of(draft),draftImages:Map.of(images))))),icon:const Icon(Icons.visibility_outlined),label:const Text('Prévia do perfil')),
   ])))]);
 })));
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
      return Column(children:[Stack(children:[PrivateImage(scope:'server', id:id, slot:'banner', size:160, borderRadius:BorderRadius.zero), Positioned(right:8,top:8,child:IconButton.filledTonal(tooltip:'Configurações do servidor',icon:const Icon(Icons.settings_outlined),onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ServerSettingsPage(id:id)))))]),
        ListTile(leading:PrivateImage(scope:'server', id:id, slot:'avatar', size:42), title:Text(d['name']?.toString()??'Servidor'),
          subtitle:Text('${(d['members'] as List?)?.length??0} membros')
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
        final canExpress=owner||(d['adminIds'] is List&&(d['adminIds'] as List).contains(myUid));
        Widget section(String title,List<Widget> children)=>children.isEmpty?const SizedBox.shrink():Padding(padding:const EdgeInsets.fromLTRB(14,16,14,6),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(color:Colors.white70,fontSize:14)),const SizedBox(height:8),Card(color:panel,margin:EdgeInsets.zero,child:Column(children:[for(var i=0;i<children.length;i++)...[if(i>0)const Divider(height:1,indent:54),children[i]]]))]));
        Widget link(IconData icon,String title,VoidCallback action)=>ListTile(leading:Icon(icon),title:Text(title),trailing:const Icon(Icons.chevron_right),onTap:action);
        void go(Widget page)=>Navigator.push(c,MaterialPageRoute(builder:(_)=>page));
        return ListView(children:[
        section('Configurações',[link(Icons.info_outline,'Visão geral',()=>go(MeowServerOverview(id:id))),if(owner)link(Icons.list,'Canais e categorias',()=>go(ServerOrganizationPage(id:id)))]),
        section('Expressões',[if(canExpress)link(Icons.emoji_emotions_outlined,'Emojis e figurinhas',()=>go(ExpressionSettings(server:id)))]),
        section('Pessoas',[link(Icons.group_outlined,'Membros',()=>showMeowMembers(c,id)),if(owner)link(Icons.link,'Convites',()=>go(Scaffold(appBar:AppBar(title:const Text('Convites')),body:MeowInvitesPage(server:id,name:d['name']?.toString()??'Servidor')))),if(owner)link(Icons.waving_hand_outlined,'Boas-vindas',()=>go(MeowWelcomeSettings(server:id)))]),
        section('Gerenciamento',[if(owner)ListTile(leading:const Icon(Icons.delete_outline,color:Colors.redAccent),title:const Text('Apagar servidor',style:TextStyle(color:Colors.redAccent)),onTap:()async{final done=await confirmServerDelete(pageContext,id);if(done&&pageContext.mounted&&ModalRoute.of(pageContext)?.isCurrent==true)Navigator.pop(pageContext);})else ListTile(leading:const Icon(Icons.logout),title:const Text('Sair do servidor'),onTap:()=>confirmLeaveServer(c,id))]),const SizedBox(height:20)]);
      }));
}
class MeowServerOverview extends StatelessWidget {
 final String id;
 const MeowServerOverview({super.key,required this.id});
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Visão geral')),
   body:MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('servers').doc(id).meowSnapshots(),builder:(c,s){
     if(s.hasError)return const Center(child:Text('Não foi possível carregar o servidor.'));
     if(!s.hasData)return const Center(child:CircularProgressIndicator());
     final d=s.data?.data();if(d==null||d['deleting']==true)return const Center(child:Text('Servidor indisponível.'));
     final owner=d['ownerId']==myUid;
     return ListView(padding:const EdgeInsets.all(16),children:[
       SizedBox(height:202,child:Stack(alignment:Alignment.topCenter,children:[
         PrivateImage(scope:'server',id:id,slot:'banner',size:160),
         Positioned(bottom:0,child:Container(padding:const EdgeInsets.all(3),decoration:const BoxDecoration(color:bg,shape:BoxShape.circle),child:PrivateImage(scope:'server',id:id,slot:'avatar',size:84))),
       ])),
       const SizedBox(height:12),Text(d['name']?.toString()??'Servidor',textAlign:TextAlign.center,style:const TextStyle(fontSize:22,fontWeight:FontWeight.bold)),
       if(owner)...[const SizedBox(height:20),ListTile(title:const Text('Renomear servidor'),trailing:const Icon(Icons.edit),onTap:()async{try{final v=await showTextPrompt(c,'Nome do servidor',d['name']?.toString()??'');if(v!=null&&v.isNotEmpty){await db.collection('servers').doc(id).update({'name':v});if(c.mounted)notice(c,'Nome atualizado.');}}catch(e){if(c.mounted)notice(c,e);}}),
         ChangeImage('server',id,'avatar','Trocar ícone (${fileSizeLabel(avatarLimit)})'),
         ChangeImage('server',id,'banner','Trocar banner (${fileSizeLabel(bannerLimit)})'),MeowEveryoneSetting(server:id)],
     ]);
   }));
}
class MeowEveryoneSetting extends StatelessWidget{
 final String server;const MeowEveryoneSetting({super.key,required this.server});
 @override Widget build(BuildContext c)=>MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('servers').doc(server).meowSnapshots(),builder:(c,s)=>SwitchListTile(title:const Text('Permitir @everyone a todos os membros'),value:s.data?.data()?['everyoneEnabled']==true,onChanged:s.hasData?(v)async{try{await db.collection('servers').doc(server).update({'everyoneEnabled':v});}catch(e){if(c.mounted)notice(c,e);}}:null));
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
  StreamSubscription<Uri>? inviteLinkSub;String? lastInviteLink;bool openingInvite=false;
  StreamSubscription<RemoteMessage>? foregroundSub,openedSub;
  OverlayEntry? notificationOverlay; Timer? notificationTimer;String? overlayThread;
  final seenNotifications=<String>{};
  String? lastOpenedNotification; DateTime? lastOpenedAt;
  Timer? presenceTimer;
  StreamSubscription<QuerySnapshot<Map<String,dynamic>>>? deletionSub;
  bool appActive = true;DateTime? pausedAt;Timer? cacheTimer;
  bool _presenceWriting=false;
  bool? _presencePending;
  bool? _presenceInFlightClosed;
  bool? _presenceLastClosed;
  DateTime? _presenceLastAttempt;
  @override void initState(){
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initNotifications();
    inviteLinkSub=meowAppLinks.uriLinkStream.listen((uri)=>unawaited(openInviteLink(uri)),onError:(Object _){});
    unawaited(meowAppLinks.getInitialLink().then<void>((uri){if(uri!=null&&mounted)WidgetsBinding.instance.addPostFrameCallback((_){if(mounted)unawaited(openInviteLink(uri));});}).catchError((Object _){}));
    touchPresence();
    unawaited(MeowCacheMaintenance.maybeClean());
    cacheTimer=Timer.periodic(const Duration(minutes:10),(_){if(appActive)unawaited(MeowCacheMaintenance.maybeClean());});
    final uid=myUid;
    deletionSub=db.collection('servers').where('members',arrayContains:uid).meowSnapshots().listen((snapshot){
      if(!mounted||FirebaseAuth.instance.currentUser?.uid!=uid)return;
      for(final d in snapshot.docs){final data=d.data();if(data['deleting']==true&&data['ownerId']==uid)MeowDeletionQueue.resume(uid,d.id);}
      final selected=serverId;
      if(selected!=null&&!snapshot.metadata.isFromCache&&!snapshot.docs.any((d)=>d.id==selected&&d.data()['deleting']!=true))setState((){serverId=null;channelId=null;showingChannels=true;});
    },onError:(Object e){debugPrint('Meow exclusões pendentes: $e');});
    presenceTimer = Timer.periodic(meowPresenceInterval, (_) {
      if (appActive) touchPresence();
    });
}
  Future<void> touchPresence({bool closed=false})async{
    final user=FirebaseAuth.instance.currentUser;if(user==null||!mounted)return;
    if(_presenceWriting){
      // Keep only the latest lifecycle intent; do not enqueue heartbeats while offline.
      _presencePending=closed==_presenceInFlightClosed?null:closed;return;
    }
    final now=DateTime.now();final last=_presenceLastAttempt;
    if(_presenceLastClosed==closed&&last!=null&&now.difference(last)<meowPresenceInterval)return;
    _presenceWriting=true;_presenceInFlightClosed=closed;_presenceLastAttempt=now;_presenceLastClosed=closed;
    try{await db.collection('users').doc(user.uid).update({'lastSeen':FieldValue.serverTimestamp(),if(closed)'presenceClosedAt':FieldValue.serverTimestamp()});}
    catch(_){MeowQuietLog.warning('presence','Meow: presença temporariamente indisponível.');}
    finally{
      _presenceWriting=false;_presenceInFlightClosed=null;
      final next=_presencePending;_presencePending=null;
      if(next!=null&&mounted&&FirebaseAuth.instance.currentUser?.uid==user.uid)unawaited(touchPresence(closed:next));
    }
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state){
    appActive=state==AppLifecycleState.resumed;
    if(appActive){final wasPaused=pausedAt!=null;final elapsed=pausedAt==null?Duration.zero:DateTime.now().difference(pausedAt!);pausedAt=null;if(wasPaused){unawaited(touchPresence());unawaited(MeowCacheMaintenance.maybeClean());if(elapsed>const Duration(seconds:3))unawaited(db.enableNetwork());}}
    else if(state==AppLifecycleState.paused||state==AppLifecycleState.hidden||state==AppLifecycleState.detached){if(pausedAt==null){pausedAt=DateTime.now();unawaited(touchPresence(closed:true));}}
    syncNativeThread();
  }
  Future<void> initNotifications()async{
    try{
      final fcm=FirebaseMessaging.instance;final registeredUid=myUid;
      await fcm.requestPermission(alert:true, badge:true, sound:true);
      if(!mounted)return;
      _meowNativeNotifications.setMethodCallHandler((call) async {
        if(!mounted||FirebaseAuth.instance.currentUser?.uid!=registeredUid)return;
        if(call.method=='openNotification'&&call.arguments is Map){
          final data=Map<String,dynamic>.from(call.arguments as Map);
          await openNotification(RemoteMessage(data:data));
        }
      });
      activeThread.addListener(syncNativeThread);
      await _nativeNotification<void>('setSession',registeredUid);
      if(!mounted||FirebaseAuth.instance.currentUser?.uid!=registeredUid)return;
      final nativeInitial=await _nativeNotification<Map<dynamic,dynamic>>('getInitialNotification');
      if(!mounted||FirebaseAuth.instance.currentUser?.uid!=registeredUid)return;
      syncNativeThread();
      if(nativeInitial!=null)WidgetsBinding.instance.addPostFrameCallback((_){if(mounted)openNotification(RemoteMessage(data:Map<String,dynamic>.from(nativeInitial)));});
      foregroundSub=FirebaseMessaging.onMessage.listen(showNotification);
      openedSub=FirebaseMessaging.onMessageOpenedApp.listen(openNotification);
      final initial=await fcm.getInitialMessage();
      if(initial!=null&&mounted)WidgetsBinding.instance.addPostFrameCallback((_){if(mounted)openNotification(initial);});
      final token=await fcm.getToken();
      if(!mounted||FirebaseAuth.instance.currentUser?.uid!=registeredUid)return;
      if(token!=null)await db.collection('users').doc(registeredUid).collection('devices').doc(token).set({
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
    tokenSub?.cancel(); inviteLinkSub?.cancel(); foregroundSub?.cancel(); openedSub?.cancel(); dismissNotification();
    activeThread.removeListener(syncNativeThread);_meowNativeNotifications.setMethodCallHandler(null);
    presenceTimer?.cancel();cacheTimer?.cancel();deletionSub?.cancel();
    super.dispose();
}
  void syncNativeThread(){final thread=appActive?activeThread.value:null;if(thread!=null&&overlayThread==thread)dismissNotification();unawaited(_nativeNotification<void>('setActiveThread',{'recipientId':FirebaseAuth.instance.currentUser?.uid,'threadKey':thread}));}
  void dismissNotification(){notificationTimer?.cancel();notificationOverlay?.remove();notificationOverlay=null;overlayThread=null;}
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
      overlayThread=threadFromPath(path);
      notificationOverlay=OverlayEntry(builder:(c)=>Positioned(top:MediaQuery.paddingOf(c).top+8,left:12,right:12,child:MeowNotificationBanner(key:ValueKey(path),sender:sender,title:userLabel(u),subtitle:message.data['kind']=='reply'?'Respondeu à sua mensagem':message.data['kind']=='mention'?'Mencionou você':path.startsWith('dms/')?'Mensagem privada':'Mensagem no servidor',preview:text.isEmpty?(message.data['notificationBody']?.toString()??'Nova mensagem'):text,onDismiss:dismissNotification,onTap:(){dismissNotification();openNotification(message);} )));
      final overlay=meowNavigator.currentState?.overlay;if(overlay==null){notificationOverlay=null;return;}
      overlay.insert(notificationOverlay!);notificationTimer=Timer(const Duration(seconds:5),dismissNotification);
    }catch(_){}
  }
  Future<void> openNotification(RemoteMessage message) async {
    if(!mounted||message.data['recipientId']!=FirebaseAuth.instance.currentUser?.uid)return;
    final path=message.data['messagePath']??'';if(!validMessagePath(path))return;
    final now=DateTime.now();if(lastOpenedNotification==path&&lastOpenedAt!=null&&now.difference(lastOpenedAt!)<const Duration(seconds:2))return;
    lastOpenedNotification=path;lastOpenedAt=now;
    try{
      final snap=await db.doc(path).get();if(!snap.exists||!mounted)return;
      final parts=path.split('/');final nav=meowNavigator.currentState;if(nav==null)return;
      if(parts.first=='dms'){
        final dm=(await db.collection('dms').doc(parts[1]).get()).data();final others=List<String>.from(dm?['members']??[]).where((x)=>x!=myUid);
        if(others.isNotEmpty&&mounted)nav.push(CupertinoPageRoute<void>(builder:(_)=>DmChatPage(id:parts[1],other:others.first,uid:myUid,initialMessageId:parts.last)));
      }else{
        final ch=(await db.collection('servers').doc(parts[1]).collection('channels').doc(parts[3]).get()).data();
        if(mounted)nav.push(MaterialPageRoute(builder:(_)=>MeowChannelHistoryPage(server:parts[1],channel:parts[3],name:ch?['name']?.toString()??'canal',uid:myUid,initialMessageId:parts.last)));
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
  Future<void> openInviteLink(Uri uri)async{
    final code=meowInviteCode(uri.toString());if(code==null||openingInvite||lastInviteLink==code||!mounted)return;lastInviteLink=code;openingInvite=true;
    try{await joinWithCode(code);}finally{openingInvite=false;lastInviteLink=null;}
  }
  Future<void> joinWithCode(String code)async{
    try{final info=await meowInviteAction({'action':'inspect','code':code});if(!mounted)return;
      final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:Text(info['name']?.toString()??'Servidor'),content:Text('${info['memberCount']??0} membros • Aceitar convite?'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancelar')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Entrar'))]));
      if(ok!=true||!mounted)return;final d=await meowInviteAction({'action':'join','code':code});if(mounted)setState((){serverId=d['serverId'].toString();channelId=null;showingChannels=true;tab=2;});
    }catch(e){if(mounted)notice(context,e);}
  }
  Future<void> joinInvite()async{
    final value=await prompt('Entrar com convite','Cole o link do convite',maxLength:300);if(!mounted||value==null)return;final code=meowInviteCode(value);if(code==null){notice(context,'Link ou convite inválido.');return;}await joinWithCode(code);
  }
    Widget rail()=>SizedBox(width:76, child:ColoredBox(color:const Color(0xFF202024), child:Column(children:[IconButton(onPressed:createServer,
  icon:const Icon(Icons.add_circle, color:purple)
), IconButton(onPressed:joinInvite, icon:const Icon(Icons.group_add)), Expanded(child:MeowStreamBuilder<QuerySnapshot<Map<String,
      dynamic>>>(stream:db.collection('servers').where('members', arrayContains:myUid).meowSnapshots(), builder:(c,
    s
)=>ListView(children:[UnreadDmRail(uid:myUid),for(final d in (s.data?.docs??[]).where((d)=>d.data()['deleting']!=true))Padding(key:ValueKey(d.id),padding:const EdgeInsets.symmetric(vertical:5),
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
        final matches=s.data!.docs.where((d)=>d.id==selected&&d.data()['deleting']!=true);
        if(matches.isEmpty){
          restoreServerNavigation(selected);
          return Row(children:[rail(),const Expanded(child:Center(child:Padding(padding:EdgeInsets.all(16),child:Text('Servidor indisponível. Selecione outro servidor.',textAlign:TextAlign.center))))]);
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
        return ChannelSlide(open:showingChannels,onMembers:()=>showMeowMembers(context,selected),onChange:(v){if(v)FocusManager.instance.primaryFocus?.unfocus();setState(()=>showingChannels=v);},
          list:Row(children:[rail(),Expanded(child:ColoredBox(color:panel,child:Column(children:[MeowCompactServerHeader(id:serverId!),Row(children:[const Expanded(child:Padding(padding:EdgeInsets.all(12),child:Text('Canais',style:TextStyle(fontSize:18)))),IconButton(onPressed:createChannel,icon:const Icon(Icons.add))]),Expanded(child:channelList(docs))])))]),
          chat:Column(children:[ListTile(leading:IconButton(icon:const Icon(Icons.arrow_back),onPressed:(){FocusManager.instance.primaryFocus?.unfocus();setState(()=>showingChannels=true);}),title:InkWell(onTap:()=>showMeowMembers(context,selected),child:MeowChannelTitle(server:selected,name:activeName)),trailing:active==null?null:Row(mainAxisSize:MainAxisSize.min,children:[MuteButton(thread:'server:$selected:$active'),MeowSearchButton(collection:db.collection('servers').doc(selected).collection('channels').doc(active).collection('messages'),openResult:(c,message)=>Navigator.pushReplacement(c,MaterialPageRoute(builder:(_)=>MeowChannelHistoryPage(server:selected,channel:active,name:activeName,uid:myUid,initialMessageId:message))))])),Expanded(child:active==null?const Center(child:Text('Sem canais')):MessageThread(key:ValueKey('$serverId/$active'),collection:db.collection('servers').doc(serverId).collection('channels').doc(active).collection('messages'),uid:myUid,serverId:serverId,threadId:'server:$serverId:$active',visible:!showingChannels&&tab==2))]));
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
    final existing = await db.collection('dmRequests').doc(id).get();
    if(existing.data()?['status']=='declined'){
      final a=await db.collection('users').doc(me).collection('following').doc(other).get();
      final b=await db.collection('users').doc(other).collection('following').doc(me).get();
      if(!a.exists||!b.exists){if(context.mounted)notice(context,'Esta solicitação foi recusada.');return;}
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
 final rows=<String,_MeowDmRow>{};
 StreamSubscription<QuerySnapshot<Map<String,dynamic>>>? rooms,followingSub,followersSub;
 Set<String> followingIds={},followerIds={};
 bool loaded=false;String? error;bool listening=false;
 @override void didChangeDependencies(){super.didChangeDependencies();final active=TickerMode.of(context);if(active&&!listening)start();if(!active&&listening)stop();}
 void start(){listening=true;followingSub=db.collection('users').doc(widget.uid).collection('following').meowSnapshots().listen((s){if(mounted&&listening)setState(()=>followingIds=s.docs.map((d)=>d.id).toSet());},onError:(Object _){});followersSub=db.collection('users').doc(widget.uid).collection('followers').meowSnapshots().listen((s){if(mounted&&listening)setState(()=>followerIds=s.docs.map((d)=>d.id).toSet());},onError:(Object _){});rooms=db.collection('dms').where('members',arrayContains:widget.uid).meowSnapshots().listen(updateRooms,onError:(Object e){if(mounted&&listening)setState(()=>error='Não foi possível carregar conversas.');});}
 void stop(){listening=false;rooms?.cancel();rooms=null;followingSub?.cancel();followersSub?.cancel();followingIds.clear();followerIds.clear();for(final r in rows.values){r.stop();}rows.clear();loaded=false;}
 void updateRooms(QuerySnapshot<Map<String,dynamic>> snapshot){if(!mounted||!listening)return;
  final ids=snapshot.docs.map((d)=>d.id).toSet();for(final id in rows.keys.toList()){if(!ids.contains(id))rows.remove(id)?.stop();}
  for(final d in snapshot.docs){if(rows.containsKey(d.id))continue;final others=List<String>.from(d.data()['members']??[]).where((x)=>x!=widget.uid);if(others.isEmpty)continue;
   final row=_MeowDmRow(d.id,others.first);rows[d.id]=row;void changed(){if(mounted&&listening&&identical(rows[d.id],row))setState((){});}
   row.subs.add(d.reference.collection('messages').orderBy('createdAt',descending:true).limit(1).meowSnapshots().listen((m){row.latest=m.docs.isEmpty?null:m.docs.first.data();row.messagesReady=true;changed();},onError:(Object e){row.latest=null;row.messagesReady=true;changed();}));
   row.subs.add(db.collection('dmRequests').doc(d.id).meowSnapshots().listen((r){row.request=r.data();row.requestReady=true;changed();},onError:(Object e){row.requestReady=false;changed();}));
   row.subs.add(db.collection('users').doc(row.other).meowSnapshots().listen((u){row.profile=u.data()??{};changed();},onError:(Object _){}));
  }
  setState((){loaded=true;error=null;});
 }
 @override void dispose(){stop();super.dispose();}
 @override Widget build(BuildContext c){
  final visible=rows.values.where((r){final status=r.request?['status'];return r.requestReady&&r.messagesReady&&r.latest!=null&&((followingIds.contains(r.other)&&followerIds.contains(r.other))||(status!='declined'&&!(status=='pending'&&r.request?['to']==widget.uid)))&&(query.isEmpty||userLabel(r.profile).toLowerCase().contains(query)||meowSerial(r.profile).contains(query.replaceFirst('#','')));}).toList()..sort((a,b){final t=b.time.compareTo(a.time);return t==0?a.id.compareTo(b.id):t;});
  const h=72.0;
  return Column(children:[ListTile(title:const Text('Mensagens privadas',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),trailing:Stack(children:[IconButton(tooltip:'Solicitações',onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>DmRequestsPage(uid:widget.uid))),icon:const Icon(Icons.mail_outline)),Positioned(right:5,top:5,child:DmRequestsDot(uid:widget.uid))])),
  Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:TextField(decoration:const InputDecoration(hintText:'Buscar por nome ou ID',prefixIcon:Icon(Icons.search)),onChanged:(v)=>setState(()=>query=v.trim().toLowerCase()))),
  Expanded(child:error!=null?Center(child:Text(error!)):!loaded?const Center(child:CircularProgressIndicator()):visible.isEmpty?const Center(child:Text('Nenhuma conversa.')):SingleChildScrollView(child:SizedBox(height:h*visible.length,child:Stack(clipBehavior:Clip.hardEdge,children:[for(var i=0;i<visible.length;i++)AnimatedPositioned(key:ValueKey(visible[i].id),duration:const Duration(milliseconds:240),curve:Curves.easeOutCubic,top:i*h,left:0,right:0,height:h,child:Builder(builder:(c){final r=visible[i];return ListTile(leading:ProfileAvatar(uid:r.other),title:Text(userLabel(r.profile)),subtitle:_MeowDmTypingPreview(id:r.id,uid:widget.uid,latest:r.latest!),trailing:ThreadUnreadDot(threadId:'dm:${r.id}',uid:widget.uid,collection:db.collection('dms').doc(r.id).collection('messages')),onTap:()=>Navigator.push(c,CupertinoPageRoute<void>(builder:(_)=>DmChatPage(id:r.id,other:r.other,uid:widget.uid))));}))]))))]);
 }
}
class _MeowDmRow {
 final String id,other;_MeowDmRow(this.id,this.other);final subs=<StreamSubscription<dynamic>>[];
 Map<String,dynamic>? latest,request;Map<String,dynamic> profile={};bool messagesReady=false,requestReady=false;
 DateTime get time {final t=latest?['createdAt'];return t is Timestamp?t.toDate():DateTime.fromMillisecondsSinceEpoch(0);}
 void stop(){for(final s in subs){unawaited(s.cancel());}subs.clear();}
}
class _MeowDmTypingPreview extends StatefulWidget {
 final String id,uid;final Map<String,dynamic> latest;const _MeowDmTypingPreview({required this.id,required this.uid,required this.latest});
 @override State<_MeowDmTypingPreview> createState()=>_MeowDmTypingPreviewState();
}
class _MeowDmTypingPreviewState extends State<_MeowDmTypingPreview>{
 Timer? timer;int frame=0;
 @override void dispose(){timer?.cancel();super.dispose();}
 @override Widget build(BuildContext c)=>MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('dms').doc(widget.id).collection('typing').meowSnapshots(),builder:(c,s){
  final typing=TickerMode.of(c)&&(s.data?.docs.any((d){final t=d.data()['at'];return d.id!=widget.uid&&t is Timestamp&&DateTime.now().difference(t.toDate()).inMilliseconds<6000;})??false);
  if(typing){timer??=Timer.periodic(const Duration(milliseconds:350),(_){if(mounted)setState(()=>frame=(frame+1)%3);});return Row(children:[const Text('Digitando',style:TextStyle(color:purple)),const SizedBox(width:4),for(var i=0;i<3;i++)AnimatedOpacity(opacity:frame==i?1:.3,duration:const Duration(milliseconds:180),child:const Text('•',style:TextStyle(color:purple)))]);}
  timer?.cancel();timer=null;final d=widget.latest;final t=(d['text']?.toString()??'').isNotEmpty?d['text'].toString():d['attachment'] is Map?'📎 Anexo':'Mensagem';return Text('${d['authorId']==widget.uid?'Você: ':''}$t',maxLines:1,overflow:TextOverflow.ellipsis);
 });
}
class DmChatPage extends StatelessWidget {
 final String id,other,uid;final String? initialMessageId;
 const DmChatPage({super.key,required this.id,required this.other,required this.uid,this.initialMessageId});
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:MeowAccountHeader(uid:other,showPresence:true,onTap:()=>openProfile(c,other)),actions:[MuteButton(thread:'dm:$id'),MeowSearchButton(collection:db.collection('dms').doc(id).collection('messages'),openResult:(c,message)=>Navigator.pushReplacement(c,CupertinoPageRoute<void>(builder:(_)=>DmChatPage(id:id,other:other,uid:uid,initialMessageId:message))))]),body:DmPermissionGate(id:id,uid:uid,other:other,initialMessageId:initialMessageId));
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
  final String? serverId,initialMessageId; final bool visible,readOnly;
  const MessageThread({
    super.key,
    required this.collection,
    required this.uid,
    required this.threadId,
    this.serverId,this.initialMessageId,this.visible=true,this.readOnly=false
}
);
  @override State<MessageThread> createState()=>_MessageThreadState();
}

class _MessageThreadState extends State<MessageThread> with RouteAware,WidgetsBindingObserver {
  final itemScroll=ItemScrollController();
  final itemPositions=ItemPositionsListener.create();
  List<QueryDocumentSnapshot<Map<String,dynamic>>> historyDocs=[];
  bool loadingHistory=false,historyEnded=false,historyWaiting=false;
  String? historyError,flashMessage;
  Timer? flashTimer,historyTimer;
  String? expectedOldest;
  int historyEpoch=0;
  QueryDocumentSnapshot<Map<String,dynamic>>? historyStart;
  Query<Map<String,dynamic>> get historyQuery=>widget.collection.orderBy('createdAt',descending:true);
  Query<Map<String,dynamic>> get windowQuery=>historyStart==null?historyQuery:historyQuery.startAtDocument(historyStart!);
  bool jumped=false,routeActive=true,foreground=true,anchored=false;
  final typingActive=ValueNotifier<bool>(false);
  Map<String,Map<String,dynamic>> people={}; bool everyoneAllowed=false;
  StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? memberSub;
  final memberSubscriptions=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};
  late Stream<QuerySnapshot<Map<String,dynamic>>> messages;
  
  int memberEpoch=0;
  Set<String> memberIds=<String>{};
  bool memberRebuildQueued=false;
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);messages=historyQuery.limit(50).snapshots(includeMetadataChanges:true);itemPositions.itemPositions.addListener(maybeLoadHistory);if(widget.visible)startMembers();if(widget.initialMessageId!=null)loadTarget();}
  void maybeLoadHistory(){
    if(!mounted||!widget.visible||!foreground||!routeActive||historyEnded||loadingHistory||historyWaiting||historyError!=null||historyDocs.length<50)return;
    final positions=itemPositions.itemPositions.value.where((p)=>p.itemTrailingEdge>0&&p.itemLeadingEdge<1);
    if(positions.any((p)=>p.index>=historyDocs.length-5)){
      WidgetsBinding.instance.addPostFrameCallback((_){if(mounted&&!loadingHistory&&!historyEnded)loadOlder();});
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }
  Future<void> loadOlder()async{
    if(loadingHistory||historyWaiting||historyEnded||historyDocs.isEmpty||!widget.visible||!foreground||!routeActive)return;
    final cursor=historyDocs.last, epoch=historyEpoch;
    setState((){loadingHistory=true;historyError=null;cachedMessagePane=null;});
    try{
      final page=await historyQuery.startAfterDocument(cursor).limit(50).get(const GetOptions(source:Source.server)).timeout(const Duration(seconds:15));
      if(!mounted||epoch!=historyEpoch)return;
      setState((){
        historyEnded=page.docs.length<50;
        if(page.docs.isNotEmpty){
          // Keep a live bounded range, including the already loaded messages.
          // A snapshot cursor includes document identity, even when timestamps tie.
          historyWaiting=true;expectedOldest=page.docs.last.id;messages=windowQuery.endAtDocument(page.docs.last).snapshots(includeMetadataChanges:true);
        }
        loadingHistory=false;cachedMessagePane=null;
      });
      historyTimer?.cancel();if(historyWaiting)historyTimer=Timer(const Duration(seconds:15),(){if(mounted&&epoch==historyEpoch&&historyWaiting)setState((){historyWaiting=false;historyEnded=false;expectedOldest=null;historyError='Não foi possível atualizar o histórico.';cachedMessagePane=null;});});
    }catch(e){if(mounted&&epoch==historyEpoch)setState((){loadingHistory=false;historyError='Não foi possível carregar mensagens antigas.';cachedMessagePane=null;});}
  }
  void resetHistory(){
    historyEpoch++;flashTimer?.cancel();historyTimer?.cancel();expectedOldest=null;
    setState((){anchored=false;jumped=true;flashMessage=null;historyStart=null;historyDocs=[];historyEnded=false;loadingHistory=false;historyWaiting=false;historyError=null;lastMarkedMessage=null;cachedMessagePane=null;messages=historyQuery.limit(50).snapshots(includeMetadataChanges:true);});
    WidgetsBinding.instance.addPostFrameCallback((_){if(mounted&&itemScroll.isAttached)itemScroll.jumpTo(index:0);});
  }
  void flashTarget(String id){
    flashTimer?.cancel();flashMessage=id;
    flashTimer=Timer(const Duration(seconds:3),(){if(mounted)setState((){flashMessage=null;cachedMessagePane=null;});});
  }
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
  Future<void> loadTarget()async {
    final epoch=historyEpoch;
    try{
      final id=widget.initialMessageId;if(id==null)return;
      final target=await widget.collection.doc(id).get();
      if(!mounted||epoch!=historyEpoch||!target.exists||target.data()?['createdAt'] is! Timestamp)return;
      final recent=await historyQuery.limit(50).get();
      if(!mounted||epoch!=historyEpoch)return;
      if(!recent.docs.any((d)=>d.id==id)){
        // Fetch the exact target by snapshot, then the surrounding older page.
        final page=await historyQuery.startAtDocument(target).limit(50).get();
        if(!mounted||epoch!=historyEpoch||page.docs.isEmpty)return;
        setState((){historyEpoch++;historyTimer?.cancel();expectedOldest=null;anchored=true;jumped=false;historyEnded=false;loadingHistory=false;historyWaiting=false;historyError=null;historyDocs=[];cachedMessagePane=null;historyStart=page.docs.first;messages=windowQuery.limit(50).snapshots(includeMetadataChanges:true);});
      }
    }catch(e){if(mounted)notice(context,'Não foi possível localizar a mensagem.');}
  }
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
  @override void didChangeAppLifecycleState(AppLifecycleState state){foreground=state==AppLifecycleState.resumed;updateActive();if(foreground&&mounted){setState((){lastMarkedMessage=null;cachedMessagePane=null;});// Active Firestore listener already resumes on foreground.
    }}
  void replyTo(QueryDocumentSnapshot<Map<String,dynamic>> doc){final d=doc.data();setState((){replyId=doc.id;replyText=d['text']?.toString()??'';replyAuthor=d['author']?.toString()??'Usuário';replyAuthorId=d['authorId']?.toString();});}
  String? get mentionQuery=>RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(input.text)?.group(1)?.toLowerCase();
  void selectMention(String name){final match=RegExp(r'@([^\s@]*)$').firstMatch(input.text);if(match==null)return;input.text=input.text.replaceRange(match.start,match.end,'@$name ');input.selection=TextSelection.collapsed(offset:input.text.length);typingChanged(input.text);}
  bool highlighted(Map<String,dynamic> d){if(d['authorId']==widget.uid)return false;final names=mentionNames(d['text']?.toString()??'');return d['replyAuthorId']==widget.uid||meowMentioned(names,widget.uid,people[widget.uid])||(names.contains('everyone')&&d['everyoneMention']==true);}
  Widget mentionSuggestions(BuildContext c,double availableHeight){
    final q=mentionQuery;
    if(q==null||availableHeight<=0)return const SizedBox.shrink();
    final matches=people.entries.where((e){final serial=meowSerial(e.value);return serial.isNotEmpty&&(userLabel(e.value).toLowerCase().contains(q)||serial.startsWith(q.replaceFirst('#','')));}).toList();
    matches.sort((a,b)=>(a.key==widget.uid?0:1).compareTo(b.key==widget.uid?0:1));final suggestions=matches.take(5).toList();
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
  final inputFocus=FocusNode();
  bool sending=false;
  Timestamp? lastMarkedMessage;
  Timer? typingTimer;
  DateTime? lastTyping;
  DocumentReference<Map<String,dynamic>> get typingRef=>widget.collection.parent!.collection('typing').doc(widget.uid);
  Future<void> stopTyping() async {typingTimer?.cancel();typingTimer=null;if(lastTyping==null)return;lastTyping=null;try{await typingRef.delete();}catch(_){} }
  void typingChanged(String value){
    if(widget.readOnly||!widget.visible||!routeActive||!foreground||value.trim().isEmpty){unawaited(stopTyping());return;}
    final now=DateTime.now();
    if(lastTyping==null||now.difference(lastTyping!).inMilliseconds>=4000){
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
    historyEpoch++;flashTimer?.cancel();historyTimer?.cancel();expectedOldest=null;itemPositions.itemPositions.removeListener(maybeLoadHistory);meowRouteObserver.unsubscribe(this);WidgetsBinding.instance.removeObserver(this);suspendMembers();if(activeThread.value==widget.threadId)activeThread.value=null;
    stopTyping();
    typingActive.dispose();
    inputFocus.dispose();
    input.dispose();
    super.dispose();
}
  Future<void> markRead()async{
    if(!widget.visible||!foreground||!routeActive)return;
    try{
      final t=lastMarkedMessage;
      await receiptRef(widget.threadId, widget.uid).set({'at':FieldValue.serverTimestamp()});
      if(t!=null&&FirebaseAuth.instance.currentUser?.uid==widget.uid)await _nativeNotification<void>('markThreadRead',{'recipientId':widget.uid,'threadKey':widget.threadId,'readAt':t.toDate().millisecondsSinceEpoch});
}catch(_){
}
}
  Future<bool> send({List<Map<String,dynamic>> attachments=const [], Map<String,dynamic>? expression})async{
    final draftAtSend=input.text;final keepKeyboard=inputFocus.hasFocus;
    final text=draftAtSend.trim();
    if(widget.readOnly||(text.isEmpty&&attachments.isEmpty&&expression==null)||sending)return false;
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
      if(attachments.isNotEmpty){data['attachment']=attachments.first;if(attachments.length>1)data['attachments']=attachments;}
      if(expression!=null)data['expression']=expression;
      if(widget.serverId!=null&&everyoneAllowed&&mentionNames(text).contains('everyone'))data['everyoneMention']=true;
      final sent=widget.collection.doc();
      if(widget.serverId==null){
        final dm=widget.collection.parent!;
        final request=db.collection('dmRequests').doc(dm.id);
        await db.runTransaction((tx)async{
          final room=await tx.get(dm);final members=List<String>.from(room.data()?['members']??[]);
          if(members.length!=2||!members.contains(widget.uid))throw Exception('Conversa indisponível.');
          final other=members.firstWhere((x)=>x!=widget.uid);
          final req=await tx.get(request);
          final a=await tx.get(db.collection('users').doc(widget.uid).collection('following').doc(other));
          final b=await tx.get(db.collection('users').doc(other).collection('following').doc(widget.uid));
          final direct=a.exists&&b.exists;
          final status=req.data()?['status'];
          if(!direct&&req.exists&&status!='accepted'&&!(status=='pending'&&req.data()?['from']==widget.uid))throw Exception('É necessário aceitar a conversa antes de responder.');
          if(!direct&&!req.exists)tx.set(request,{'from':widget.uid,'to':other,'status':'pending','createdAt':FieldValue.serverTimestamp(),'firstMessageId':sent.id});
          tx.set(sent,data);
        });
      }else{await sent.set(data);}
      unawaited(notifyMessage(sent.path));
      if(!mounted)return true;
      if(input.text==draftAtSend){input.clear();unawaited(stopTyping());}
      if(mounted)setState((){
        replyId=null;
        replyText=null;
        replyAuthor=null;replyAuthorId=null;
}
);
      await markRead();return true;
}catch(e){
      if(mounted)notice(context, 'Falha ao enviar: $e');return false;
}finally{
      if(mounted){setState(()=>sending=false);if(keepKeyboard&&routeActive&&widget.visible&&foreground)inputFocus.requestFocus();}
}
}
  bool uploading=false;double? uploadProgress;
  final pendingAttachments=<MeowPendingAttachment>[];
  Future<void> attach()async{
    if(uploading||sending||widget.readOnly)return;
    try{
      final remaining=5-pendingAttachments.length;if(remaining<=0){notice(context,'Até 5 arquivos por mensagem.');return;}
      final selected=await showModalBottomSheet<List<files.XFile>>(context:context,isScrollControlled:true,showDragHandle:true,backgroundColor:panel,builder:(_)=>MeowAttachmentPicker(maxCount:remaining));
      if(selected==null)return;
      if(!mounted)return;
      final added=<MeowPendingAttachment>[];
      for(final file in selected){
        if(pendingAttachments.length+added.length>=5){notice(context,'Até 5 arquivos por mensagem.');break;}
        final length=await file.length();if(!mounted)return;
        if(length<1||length>attachmentLimit){notice(context,'${file.name}: limite de ${fileSizeLabel(attachmentLimit)} por arquivo.');continue;}
        added.add(MeowPendingAttachment(file,length));
      }
      if(mounted)setState(()=>pendingAttachments.addAll(added));
    }catch(e){if(mounted)notice(context,'Não foi possível selecionar arquivo: $e');}
  }
  Future<Map<String,dynamic>> uploadOne(MeowPendingAttachment entry,int index,int total)async{
      final file=entry.file;final length=entry.length;
      final name = file.name;
      final contentType=entry.mime;
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
              if(mounted&&(transferred>=length||now.difference(lastPaint)>=const Duration(milliseconds:120))){lastPaint=now;setState(()=>uploadProgress=((index+transferred/length)/total).clamp(0.0,1.0).toDouble());}
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
        final resultData=<String,dynamic>{'id':payload['id'],'name':payload['name'],'contentType':payload['contentType'],'size':payload['size']};
        if(contentType.startsWith('video/')&&mounted&&FirebaseAuth.instance.currentUser?.uid==widget.uid){try{final thumb=await VideoThumbnail.thumbnailData(video:file.path,imageFormat:ImageFormat.JPEG,maxWidth:480,quality:75).timeout(const Duration(seconds:10));if(thumb.isNotEmpty&&thumb.length<=500000&&FirebaseAuth.instance.currentUser?.uid==widget.uid){final thumbResponse=await http.put(Uri.https(imageHost,'/functions/v1/meow-anexos',{'thread':widget.threadId,'name':'preview.jpg'}),headers:{...await authHeaders(),'Content-Type':'image/jpeg'},body:thumb).timeout(const Duration(seconds:15));if(thumbResponse.statusCode==201){final value=jsonDecode(thumbResponse.body);if(value is Map&&value['id'] is String&&value['id'].toString().split('.').first==payload['id'].toString().split('.').first)resultData['thumbnailId']=value['id'];}}}catch(_){/* The original video remains sendable if thumbnail creation fails. */}}
        return resultData;
      }finally{client.close();}
  }
  Future<void> sendQueued({Map<String,dynamic>? expression})async{
    if(sending||uploading||widget.readOnly)return;
    if(pendingAttachments.isEmpty){await send(expression:expression);return;}
    final items=List<MeowPendingAttachment>.from(pendingAttachments);
    setState((){uploading=true;uploadProgress=0;});
    try{
      for(var i=0;i<items.length;i++){
        if(!mounted||FirebaseAuth.instance.currentUser?.uid!=widget.uid)return;
        final item=items[i];item.uploaded??=await uploadOne(item,i,items.length);
        if(mounted)setState(()=>uploadProgress=(i+1)/items.length);
      }
      if(!mounted||FirebaseAuth.instance.currentUser?.uid!=widget.uid)return;
      final ok=await send(attachments:items.map((e)=>e.uploaded!).toList(),expression:expression);
      if(ok&&mounted)setState(()=>pendingAttachments.clear());
    }catch(e){if(mounted)notice(context,'Anexo não enviado: $e. Toque em Enviar para tentar novamente.');}
    finally{if(mounted)setState((){uploading=false;uploadProgress=null;});}
  }
  Widget attachmentTray()=>SizedBox(height:104,child:ListView(scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:8,vertical:6),children:[for(final item in pendingAttachments)Padding(padding:const EdgeInsets.only(right:8),child:Stack(children:[Container(width:item.mime.startsWith('image/')?94:178,height:92,clipBehavior:Clip.antiAlias,decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(12)),child:item.mime.startsWith('image/')?Image.file(File(item.file.path),fit:BoxFit.cover,cacheWidth:200,errorBuilder:(_,__,___)=>const Icon(Icons.image)):Padding(padding:const EdgeInsets.all(12),child:Row(children:[Icon(item.mime.startsWith('video/')?Icons.movie:Icons.insert_drive_file,color:Colors.white70),const SizedBox(width:8),Expanded(child:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(item.file.name,maxLines:1,overflow:TextOverflow.ellipsis),Text(fileSizeLabel(item.length),style:const TextStyle(fontSize:11,color:Colors.white54))]))]))),Positioned(right:0,top:0,child:IconButton.filledTonal(visualDensity:VisualDensity.compact,tooltip:'Remover anexo',onPressed:uploading||sending?null:()=>setState(()=>pendingAttachments.remove(item)),icon:const Icon(Icons.close,size:16))) ]))]));
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
        children:[if(!widget.readOnly)ListTile(leading:const Icon(Icons.add_reaction_outlined),title:const Text('Adicionar reação'),onTap:()=>Navigator.pop(c,'react')),if(!widget.readOnly)ListTile(leading:const Icon(Icons.reply), title:const Text('Responder'), onTap:()=>Navigator.pop(c,
      'reply'
)), if((d['text']?.toString()??'').isNotEmpty)ListTile(leading:const Icon(Icons.copy), title:const Text('Copiar mensagem'), onTap:()=>Navigator.pop(c, 'copy')), if(meowAttachments(d).isNotEmpty)ListTile(leading:const Icon(Icons.download),title:const Text('Salvar anexo'),onTap:()=>Navigator.pop(c,'download')),if(own)ListTile(leading:const Icon(Icons.edit), title:const Text('Editar'), onTap:()=>Navigator.pop(c,
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
    if(action=='download'){final list=meowAttachments(d);final selected=list.length==1?list.first:await showModalBottomSheet<Map<String,dynamic>>(context:context,builder:(c)=>SafeArea(child:ListView(shrinkWrap:true,children:[for(final a in list)ListTile(title:Text(a['name'].toString()),onTap:()=>Navigator.pop(c,a))])));if(selected!=null&&mounted){try{final bytes=await PrivateMediaCache.get(attachmentUrl(selected['id'].toString()));if(bytes==null)throw Exception('Anexo indisponível.');if(mounted)await saveMeowFile(context,bytes,selected['name'].toString(),selected['contentType'].toString().startsWith('image/'));}catch(e){if(mounted)notice(context,e);}}}
    if(action=='reply')replyTo(doc);
    if(action=='react'&&!widget.readOnly)await addReaction(context,doc.reference,widget.uid);
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
        if(s.connectionState==ConnectionState.active){
          final previous=historyDocs;
          if(previous.isNotEmpty&&docs.isNotEmpty&&previous.first.id!=docs.first.id&&itemScroll.isAttached){
            final visible=itemPositions.itemPositions.value.where((p)=>p.itemLeadingEdge>=0&&p.itemLeadingEdge<1&&p.index<previous.length).toList();
            visible.sort((a,b)=>a.itemLeadingEdge.compareTo(b.itemLeadingEdge));
            if(visible.isNotEmpty&&!visible.any((p)=>p.index==0)){
              final anchor=visible.first;final id=previous[anchor.index].id;
              final index=docs.indexWhere((d)=>d.id==id);
              if(index>=0&&index!=anchor.index)WidgetsBinding.instance.addPostFrameCallback((_){if(mounted&&itemScroll.isAttached)itemScroll.jumpTo(index:index,alignment:anchor.itemLeadingEdge);});
            }
          }
          historyDocs=docs;
          if(!s.data!.metadata.isFromCache&&(expectedOldest==null||docs.any((d)=>d.id==expectedOldest))){historyWaiting=false;expectedOldest=null;historyTimer?.cancel();if(docs.length<50)historyEnded=true;}
        }
        if(docs.isEmpty)return const Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Image(image:AssetImage('assets/meow_foreground.png'),width:72,height:72),SizedBox(height:12),Text('Comece a conversa!')]));
        final newest = docs.first.data()['createdAt'];
        if (widget.visible && foreground && routeActive && newest is Timestamp && newest != lastMarkedMessage && !anchored) {
          lastMarkedMessage = newest;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) markRead();
          });
        }
          final targetIndex=docs.indexWhere((d)=>d.id==widget.initialMessageId);
          if(targetIndex>=0&&!jumped){jumped=true;flashTarget(docs[targetIndex].id);WidgetsBinding.instance.addPostFrameCallback((_){if(mounted&&itemScroll.isAttached)itemScroll.jumpTo(index:targetIndex,alignment:.35);});}
          return ScrollablePositionedList.builder(key:PageStorageKey<String>(widget.threadId),itemScrollController:itemScroll,itemPositionsListener:itemPositions,reverse:true,padding:const EdgeInsets.all(12),itemCount:docs.length+1,itemBuilder:(c,
        i
){
          if(i==docs.length)return Center(child:Padding(padding:const EdgeInsets.symmetric(vertical:8),child:loadingHistory||historyWaiting?const SizedBox(width:20,height:20,child:CircularProgressIndicator(strokeWidth:2)):historyError!=null?TextButton(onPressed:loadOlder,child:Text('$historyError Tentar novamente')):historyEnded?const Text('Início da conversa',style:TextStyle(color:Colors.white54,fontSize:12)):TextButton(onPressed:loadOlder,child:const Text('Carregar mensagens anteriores'))));
          final doc=docs[i],
          d=doc.data();
          final author=d['authorId']?.toString()??'';
          if(widget.serverId!=null&&author=='system'&&d['systemType']=='member_join')return Padding(padding:const EdgeInsets.symmetric(vertical:12,horizontal:6),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[const Icon(Icons.arrow_forward,color:Color(0xFF39C981),size:22),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[InkWell(onTap:()=>openProfile(c,d['joinedUid']?.toString()??''),child:Text(d['text']?.toString()??'Um novo membro chegou!',style:const TextStyle(fontWeight:FontWeight.w600))),Text(d['createdAt'] is Timestamp?formatMeowTime((d['createdAt'] as Timestamp).toDate()):'',style:const TextStyle(fontSize:11,color:Colors.white54))]))]));
          final attachments=meowAttachments(d);
          final older=i+1<docs.length?docs[i+1].data():null;
          bool sameGroup(Map<String,dynamic>? other)=>other!=null&&other['authorId']==author&&other['createdAt'] is Timestamp&&d['createdAt'] is Timestamp&&(d['createdAt'] as Timestamp).toDate().difference((other['createdAt'] as Timestamp).toDate()).inSeconds.abs()<300;
          final grouped=sameGroup(older);
          final when=d['createdAt'] is Timestamp?formatMeowTime((d['createdAt'] as Timestamp).toDate()):'Enviando...';
          final isDm=widget.serverId==null;
          final mine=author==widget.uid;
          final name=people.containsKey(author)?userLabel(people[author]!):d['author']?.toString()??'Usuário';
          final rawText=d['text']?.toString()??'';
          final soloEmoji=MeowMessageText.isEmojiOnly(rawText);
          final textContents=<Widget>[
            if(d['replyToId']!=null)Container(padding:const EdgeInsets.only(left:6),decoration:const BoxDecoration(border:Border(left:BorderSide(color:Colors.white38,width:2))),child:DefaultTextStyle.merge(style:const TextStyle(color:Colors.white70,fontSize:12),child:MeowMessageText(text:'↳ ${d['replyAuthor']??''}: ${d['replyText']??''}',people:people,compact:true))),
            if(rawText.isNotEmpty&&meowInviteCode(rawText,linkOnly:true)==null)MeowMessageText(text:rawText,people:people),
          ];
          final mediaContents=<Widget>[
            if(meowInviteCode(rawText,linkOnly:true)!=null)MeowInviteCard(key:ValueKey(doc.id),code:meowInviteCode(rawText,linkOnly:true)!),
            for(final attachment in attachments)AttachmentView(key:ValueKey(attachment['id']),attachment:attachment),
            if(d['expression'] is Map)ExpressionImage(data:Map<String,dynamic>.from(d['expression'] as Map),message:doc.reference.path,size:(d['expression'] as Map)['kind']=='emoji'&&(d['text']?.toString()??'').isNotEmpty?26.0:null),
          ];
          final tailContents=<Widget>[
            if(!widget.readOnly)ReactionBar(ref:doc.reference,uid:widget.uid),
            if(d['editedAt']!=null)const Text('(editada)',style:TextStyle(fontSize:11,color:Colors.white54)),
          ];
          final messageContents=<Widget>[...textContents,...mediaContents,...tailContents];
          final Widget messageBody;
          if(isDm){
            messageBody=Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
              if(!mine)...[if(grouped)const SizedBox(width:meowChatAvatarSize)else ProfileAvatar(uid:author,size:meowChatAvatarSize,showPresence:false),const SizedBox(width:8)],
              Expanded(child:Align(alignment:mine?Alignment.centerRight:Alignment.centerLeft,child:FractionallySizedBox(widthFactor:.88,alignment:mine?Alignment.centerRight:Alignment.centerLeft,child:Column(crossAxisAlignment:mine?CrossAxisAlignment.end:CrossAxisAlignment.start,children:[
                if(!grouped)Padding(padding:const EdgeInsets.only(bottom:4),child:Text(when,style:const TextStyle(fontSize:12,color:Colors.white70))),
                if(textContents.isNotEmpty)
                  if(soloEmoji&&d['replyToId']==null) ...textContents
                  else Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),decoration:BoxDecoration(color:mine?const Color(0xFF6440A9):panel,borderRadius:BorderRadius.circular(16),border:highlighted(d)?Border.all(color:Colors.amber,width:1):null),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:textContents)),
                ...mediaContents,...tailContents,
              ])))),
              if(mine)...[const SizedBox(width:8),if(grouped)const SizedBox(width:meowChatAvatarSize)else ProfileAvatar(uid:author,size:meowChatAvatarSize,showPresence:false)],
            ]);
          }else{
            messageBody=Row(crossAxisAlignment:CrossAxisAlignment.start,children:[grouped?const SizedBox(width:meowChatAvatarSize):ProfileAvatar(uid:author,size:meowChatAvatarSize,showPresence:false),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              if(!grouped)Row(children:[Flexible(child:InkWell(onTap:()=>openProfile(c,author),child:Text(name,style:const TextStyle(fontWeight:FontWeight.bold,color:purple)))),const SizedBox(width:8),Text(when,style:const TextStyle(fontSize:11,color:Colors.white54))]),...messageContents,
            ]))]);
          }
          return ReplySwipe(key:ValueKey(doc.id),onReply:(){if(!widget.readOnly)replyTo(doc);},child:InkWell(onLongPress:()=>options(doc),child:Container(
            decoration:flashMessage==doc.id?BoxDecoration(color:purple.withOpacity(.22),borderRadius:BorderRadius.circular(8)):!isDm&&highlighted(d)?const BoxDecoration(color:Color(0x22FFC107),border:Border(left:BorderSide(color:Colors.amber,width:3))):null,
            padding:EdgeInsets.symmetric(vertical:grouped?2:5,horizontal:4),child:messageBody)));

}
);
}
)
);
    @override Widget build(BuildContext c)=>Column(children:[if(anchored)TextButton(onPressed:resetHistory,child:const Text('Voltar às mensagens recentes')),messageArea(), if(uploading)LinearProgressIndicator(value:uploadProgress),ValueListenableBuilder<bool>(valueListenable:typingActive,builder:(c,active,_)=>active?TypingLabel(collection:widget.collection.parent!.collection('typing'),uid:widget.uid):const SizedBox.shrink()), if(!widget.readOnly&&replyId!=null)ListTile(dense:true, title:Text('Respondendo a $replyAuthor: $replyText', maxLines:1,
  overflow:TextOverflow.ellipsis
), trailing:IconButton(icon:const Icon(Icons.close), onPressed:()=>setState((){
    replyId=null;
    replyText=null;
    replyAuthor=null;replyAuthorId=null;
}
))), if(!widget.readOnly&&pendingAttachments.isNotEmpty)attachmentTray(),if(!widget.readOnly)SafeArea(top:false, child:Padding(padding:const EdgeInsets.all(8), child:Row(children:[IconButton(tooltip:'Anexar arquivo',
  onPressed:(sending||uploading)?null:attach, icon:Icon(uploading?Icons.hourglass_top:Icons.add_circle_outline)
), Expanded(child:TextField(controller:input,focusNode:inputFocus, maxLength:2000, maxLines:4, minLines:1, decoration:InputDecoration(hintText:'Mensagem',counterText:'',border:OutlineInputBorder(borderRadius:BorderRadius.circular(24))), onChanged:typingChanged,onEditingComplete:(){if(!uploading&&!sending)sendQueued();})), IconButton(tooltip:'Emojis e figurinhas',icon:const Icon(Icons.emoji_emotions_outlined),onPressed:(sending||uploading)?null:()async{final v=await pickExpression(context);if(!mounted||v==null)return;if(v is String){input.text+=v;typingChanged(input.text);}else if(v is Map<String,dynamic>){await sendQueued(expression:v);}}), IconButton(onPressed:(sending||uploading)?null:()=>sendQueued(), icon:const Icon(Icons.send,
  color:purple
))])))]);
}

List<Map<String,dynamic>> meowAttachments(Map<String,dynamic> data){
 final raw=data['attachments'];if(raw is List){final all=raw.whereType<Map>().where((a)=>a['id'] is String).map((a)=>Map<String,dynamic>.from(a)).toList();if(all.isNotEmpty)return all;}
 final one=data['attachment'];return one is Map&&one['id'] is String?[Map<String,dynamic>.from(one)]:[];
}
class MeowPendingAttachment{
 final files.XFile file;final int length;final String mime;Map<String,dynamic>? uploaded;
 MeowPendingAttachment(this.file,this.length):mime=meowFileMime(file.name);
}
String meowFileMime(String name)=>const {'jpg':'image/jpeg','jpeg':'image/jpeg','png':'image/png','gif':'image/gif','webp':'image/webp','pdf':'application/pdf','txt':'text/plain','mp4':'video/mp4','mov':'video/quicktime','webm':'video/webm','m4v':'video/mp4','mp3':'audio/mpeg','wav':'audio/wav','zip':'application/zip','apk':'application/vnd.android.package-archive'}[name.split('.').last.toLowerCase()]??'application/octet-stream';
class AttachmentView extends StatefulWidget {
 final Map attachment;const AttachmentView({super.key,required this.attachment});
 @override State<AttachmentView> createState()=>_AttachmentViewState();
}
class _AttachmentViewState extends State<AttachmentView>{
 Future<Uint8List?>? imageFuture;bool busy=false;double? downloadProgress;
 bool get isImage=>(widget.attachment['contentType']?.toString()??'').startsWith('image/');
 Future<Uint8List?> fetch()=>PrivateMediaCache.get(attachmentUrl(widget.attachment['id'].toString()));
 @override void initState(){super.initState();if(isImage)imageFuture=fetch();}
 Future<void> save()async{if(busy)return;setState((){busy=true;downloadProgress=null;});try{final bytes=await PrivateMediaCache.get(attachmentUrl(widget.attachment['id'].toString()),onProgress:(v){if(mounted)setState(()=>downloadProgress=v);});if(bytes==null)throw Exception('Arquivo indisponível.');if(!mounted)return;await saveMeowFile(context,bytes,widget.attachment['name']?.toString()??'arquivo',isImage); }catch(e){if(mounted)notice(context,e);}finally{if(mounted)setState(()=>busy=false);}}
 @override void didUpdateWidget(covariant AttachmentView old){
   super.didUpdateWidget(old);
   if(old.attachment['id']!=widget.attachment['id']||old.attachment['contentType']!=widget.attachment['contentType']){
     imageFuture=isImage?fetch():null;
   }
 }
 @override Widget build(BuildContext c){
   final name=widget.attachment['name']?.toString()??'Arquivo';
   if((widget.attachment['contentType']?.toString()??'').startsWith('video/'))return MeowVideoAttachment(key:ValueKey(widget.attachment['id']),attachment:widget.attachment);
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
       trailing:busy?SizedBox(width:28,height:28,child:CircularProgressIndicator(value:downloadProgress,strokeWidth:3)):IconButton(tooltip:'Salvar arquivo',onPressed:save,icon:const Icon(Icons.download)),
     ),
   );
 }
}
// Media files are private, bounded by the existing 25 MiB attachment limit.
// Active players hold a lease; cache cleanup never deletes an active file.
class MeowVideoCache {
 static final active=<String>{};
 static Future<Directory> directory()async{final base=await getTemporaryDirectory();return Directory('${base.path}/meow_video_091')..createSync(recursive:true);}
 static Future<File> acquire(Map attachment)async{
  final id=attachment['id'].toString();final uid=myUid;
  final dir=await directory();final ext=const {'video/mp4':'mp4','video/quicktime':'mov','video/webm':'webm'}[attachment['contentType']]??'mp4';
  final file=File('${dir.path}/${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1<<30)}.$ext');
  active.add(file.path);
  final client=http.Client();
  try{
   final request=http.Request('GET',attachmentUrl(id));request.headers.addAll(await authHeaders());
   final response=await client.send(request).timeout(const Duration(seconds:30));
   if(response.statusCode!=200||(response.contentLength??0)>attachmentLimit)throw Exception('Vídeo indisponível.');
   var size=0;final sink=file.openWrite();
   try{await for(final chunk in response.stream.timeout(const Duration(seconds:30))){if(FirebaseAuth.instance.currentUser?.uid!=uid)throw Exception('Sessão alterada.');size+=chunk.length;if(size>attachmentLimit)throw Exception('Vídeo acima do limite.');sink.add(chunk);}}finally{await sink.close();}
   if(size==0||FirebaseAuth.instance.currentUser?.uid!=uid)throw Exception('Vídeo indisponível.');
   return file;
  }catch(_){await release(file);rethrow;}finally{client.close();}
 }
 static Future<void> release(File? file)async{if(file==null)return;active.remove(file.path);try{if(await file.exists())await file.delete();}catch(_){} }
 static Future<int> bytes()async{var size=0;try{final dir=await directory();await for(final e in dir.list(followLinks:false)){if(e is File)size+=await e.length();}}catch(_){}return size;}
 static Future<void> clear()async{try{final dir=await directory();await for(final e in dir.list(followLinks:false)){if(e is File&&!active.contains(e.path)){try{await e.delete();}catch(_){}}}}catch(_){} }
}
class MeowVideoAttachment extends StatefulWidget {
 final Map attachment;const MeowVideoAttachment({super.key,required this.attachment});
 @override State<MeowVideoAttachment> createState()=>_MeowVideoAttachmentState();
}
class _MeowVideoAttachmentState extends State<MeowVideoAttachment> with RouteAware,WidgetsBindingObserver {
 File? file;VideoPlayerController? player;Uint8List? thumbnail;double thumbnailAspect=16/9;bool preparing=false,opening=false,full=false,failed=false,visible=true,foreground=true;int epoch=0;
 Future<void>? preparation;
 @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);unawaited(loadThumbnail());}
 Future<void> loadThumbnail()async{final id=widget.attachment['thumbnailId'];if(id is! String||id.split('.').first!=widget.attachment['id'].toString().split('.').first)return;try{final bytes=await PrivateMediaCache.get(attachmentUrl(id));if(bytes==null||bytes.length>500000||!mounted)return;final codec=await ui.instantiateImageCodec(bytes);final frame=await codec.getNextFrame();final ratio=frame.image.width/frame.image.height;frame.image.dispose();codec.dispose();if(mounted)setState((){thumbnail=bytes;thumbnailAspect=ratio;});}catch(_){} }
 @override void didChangeDependencies(){super.didChangeDependencies();final route=ModalRoute.of(context);if(route!=null)meowRouteObserver.subscribe(this,route);visible=TickerMode.of(context)&&(route?.isCurrent??true);if(!visible||!foreground){if(!full)player?.pause();}}
 Future<void> prepare()async{if(preparation!=null){await preparation;return;}final generation=++epoch;setState((){preparing=true;failed=false;});final task=()async{
   try{final f=await MeowVideoCache.acquire(widget.attachment);if(!mounted||generation!=epoch){await MeowVideoCache.release(f);return;}file=f;
    try{final thumb=await VideoThumbnail.thumbnailData(video:f.path,imageFormat:ImageFormat.JPEG,maxWidth:480,quality:75);final codec=await ui.instantiateImageCodec(thumb);final frame=await codec.getNextFrame();final ratio=frame.image.width/frame.image.height;frame.image.dispose();codec.dispose();if(mounted&&generation==epoch)setState((){thumbnail=thumb;thumbnailAspect=ratio;});}catch(_){/* Playback can still work without a preview. */}
   }catch(_){if(mounted&&generation==epoch){setState(()=>failed=true);await MeowVideoCache.release(file);file=null;}}
   finally{if(mounted&&generation==epoch)setState(()=>preparing=false);}
  }();preparation=task;await task;
 }
 Future<VideoPlayerController?> ready()async{
  if(failed){preparation=null;await prepare();}else if(preparation==null){await prepare();}else{await preparation;}
  if(!mounted||file==null||failed)return null;
  if(player?.value.isInitialized==true)return player;
  final next=VideoPlayerController.file(file!);try{await next.initialize();if(!mounted){await next.dispose();return null;}if(player!=null)await player!.dispose();player=next;setState((){});return next;}catch(_){await next.dispose();if(mounted){notice(context,'Formato de vídeo não compatível.');}return null;}
 }
 Future<void> tap({bool fullscreen=false})async{
  if(opening||full)return;opening=true;
  try{final p=await ready();if(!mounted||p==null||!visible||!foreground)return;
   if(fullscreen||p.value.isPlaying){if(!p.value.isPlaying){if(p.value.position>=p.value.duration)await p.seekTo(Duration.zero);await p.play();}if(!mounted)return;full=true;setState((){});await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>MeowFullVideo(player:p)));if(!mounted)return;full=false;setState((){});if(!visible||!foreground)await p.pause();}
   else{if(p.value.position>=p.value.duration)await p.seekTo(Duration.zero);await p.play();}
  }finally{opening=false;}
 }
 @override void didPushNext(){visible=false;if(!full)player?.pause();}
 @override void didPopNext(){visible=TickerMode.of(context);}
 @override void didPop(){if(!full)player?.pause();}
 @override void didChangeAppLifecycleState(AppLifecycleState state){foreground=state==AppLifecycleState.resumed;if(!foreground)player?.pause();}
 @override void dispose(){epoch++;meowRouteObserver.unsubscribe(this);WidgetsBinding.instance.removeObserver(this);final p=player;final f=file;unawaited(()async{try{await p?.dispose();}finally{await MeowVideoCache.release(f);}}());super.dispose();}
 @override Widget build(BuildContext c){final p=player;return Container(margin:const EdgeInsets.only(top:5),constraints:const BoxConstraints(maxWidth:320,maxHeight:340),child:ClipRRect(borderRadius:BorderRadius.circular(12),child:p!=null&&p.value.isInitialized&&!full?MeowVideoSurface(player:p,onTap:()=>tap(),onDoubleTap:()=>tap(fullscreen:true)):AspectRatio(aspectRatio:thumbnailAspect,child:GestureDetector(onTap:()=>tap(),onDoubleTap:()=>tap(fullscreen:true),child:Stack(fit:StackFit.expand,children:[ColoredBox(color:panel,child:thumbnail==null?const Center(child:Icon(Icons.movie_outlined,color:Colors.white54,size:32)):Image.memory(thumbnail!,fit:BoxFit.contain,gaplessPlayback:true)),Center(child:Container(padding:const EdgeInsets.all(14),decoration:const BoxDecoration(color:Colors.black54,shape:BoxShape.circle),child:preparing?const SizedBox(width:25,height:25,child:CircularProgressIndicator(strokeWidth:2)):Icon(failed?Icons.refresh:Icons.play_arrow,color:Colors.white,size:30))) ])))));}
}
class MeowVideoSurface extends StatelessWidget{
 final VideoPlayerController player;final VoidCallback onTap,onDoubleTap;final bool full;
 const MeowVideoSurface({super.key,required this.player,required this.onTap,required this.onDoubleTap,this.full=false});
 @override Widget build(BuildContext c)=>ValueListenableBuilder<VideoPlayerValue>(valueListenable:player,builder:(c,v,_){
  final duration=max(1,v.duration.inMilliseconds);final position=v.position.inMilliseconds.clamp(0,duration).toDouble();
  return AspectRatio(aspectRatio:v.aspectRatio>0?v.aspectRatio:16/9,child:Stack(fit:StackFit.expand,children:[GestureDetector(behavior:HitTestBehavior.opaque,onTap:onTap,onDoubleTap:onDoubleTap,child:VideoPlayer(player)),if(!v.isPlaying)Center(child:IgnorePointer(child:Container(decoration:const BoxDecoration(color:Colors.black54,shape:BoxShape.circle),padding:const EdgeInsets.all(12),child:const Icon(Icons.play_arrow,size:32,color:Colors.white)))),Positioned(left:0,right:0,bottom:0,child:Container(color:Colors.black54,child:Row(children:[IconButton(visualDensity:VisualDensity.compact,onPressed:()=>v.isPlaying?player.pause():player.play(),icon:Icon(v.isPlaying?Icons.pause:Icons.play_arrow,color:Colors.white,size:20)),Expanded(child:Slider(value:position,max:duration.toDouble(),onChanged:(n)=>player.seekTo(Duration(milliseconds:n.round())))),IconButton(visualDensity:VisualDensity.compact,onPressed:()=>player.setVolume(v.volume>0?0:1),icon:Icon(v.volume>0?Icons.volume_up:Icons.volume_off,color:Colors.white,size:20))])))]));
 });
}
class MeowFullVideo extends StatelessWidget{
 final VideoPlayerController player;const MeowFullVideo({super.key,required this.player});
 @override Widget build(BuildContext c)=>Scaffold(backgroundColor:Colors.black,appBar:AppBar(backgroundColor:Colors.black),body:Center(child:MeowVideoSurface(player:player,full:true,onTap:()=>player.value.isPlaying?player.pause():player.play(),onDoubleTap:()=>Navigator.maybePop(c))));
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
    for(final d in found)ListTile(leading:ProfileAvatar(uid:d.id),title:Text(userLabel(d.data())),onTap:()=>Navigator.pop(sheet,d.id))])));
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
 @override void initState(){super.initState();following=db.collection('users').doc(widget.uid).collection('following').meowSnapshots().listen((s){if(!mounted)return;final ids=s.docs.map((d)=>d.id).toSet();for(final id in mutualSubs.keys.toList()){if(!ids.contains(id)){mutualSubs.remove(id)?.cancel();profileSubs.remove(id)?.cancel();profiles.remove(id);}}for(final id in ids){mutualSubs.putIfAbsent(id,()=>db.collection('users').doc(id).collection('following').doc(widget.uid).meowSnapshots().listen((m){if(!mounted||!mutualSubs.containsKey(id))return;if(m.exists){profiles.putIfAbsent(id,()=>{});profileSubs.putIfAbsent(id,()=>db.collection('users').doc(id).meowSnapshots().listen((u){if(mounted&&profileSubs.containsKey(id))setState(()=>profiles[id]=u.data()??{});}));}else{profileSubs.remove(id)?.cancel();profiles.remove(id);}setState((){});}));}setState(()=>loaded=true);},onError:(Object _){if(mounted)setState(()=>loaded=true);});timer=Timer.periodic(const Duration(seconds:5),(_){if(mounted)setState((){});});}
 @override void dispose(){following?.cancel();timer?.cancel();for(final s in mutualSubs.values){s.cancel();}for(final s in profileSubs.values){s.cancel();}super.dispose();}
 @override Widget build(BuildContext c){if(!loaded)return const Center(child:CircularProgressIndicator());if(profiles.isEmpty)return const Center(child:Text('Nenhum amigo ainda.'));final entries=profiles.entries.toList()..sort((a,b){final offA=currentPresence(a.value)=='offline';final offB=currentPresence(b.value)=='offline';if(offA!=offB)return offA?1:-1;return userLabel(a.value).compareTo(userLabel(b.value));});return ListView(children:[for(final e in entries)ListTile(leading:ProfileAvatar(uid:e.key),title:Text(userLabel(e.value)),dense:false,visualDensity:VisualDensity.standard,contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:5),onTap:()=>openProfile(c,e.key))]);}
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
   FilledButton(onPressed:saving?null:()async{setState(()=>saving=true);try{if(mounted)notice(context,'Use Editar perfil para salvar o tema.');}catch(e){if(mounted)notice(context,e);}finally{if(mounted)setState(()=>saving=false);}},child:Text(saving?'Salvando...':'Salvar tema')),
  ]);
 });
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
 final String uid;const DmRequestsPage({super.key,required this.uid});
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Solicitações de mensagens')),body:MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:myDmRequests(uid),builder:(c,s){
  if(s.hasError)return const Center(child:Text('Não foi possível carregar solicitações.'));
  if(!s.hasData)return const Center(child:CircularProgressIndicator());
  if(s.data!.docs.isEmpty)return const Center(child:Text('Nenhuma solicitação pendente.'));
  return ListView(children:[for(final request in s.data!.docs)MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(key:ValueKey(request.id),stream:db.collection('dms').doc(request.id).collection('messages').orderBy('createdAt',descending:true).limit(1).meowSnapshots(),builder:(c,m){
    if(m.data?.docs.isNotEmpty!=true)return const SizedBox.shrink();
    final from=request.data()['from'].toString();
    return ListTile(leading:ProfileAvatar(uid:from),title:UserDisplayName(uid:from),subtitle:DmPreview(id:request.id,uid:uid),trailing:ThreadUnreadDot(threadId:'dm:${request.id}',uid:uid,collection:db.collection('dms').doc(request.id).collection('messages')),onTap:()=>Navigator.push(c,CupertinoPageRoute<void>(builder:(_)=>DmChatPage(id:request.id,other:from,uid:uid))));
  })]);
 }));
}

class DmPermissionGate extends StatelessWidget {
 final String id,uid,other;final String? initialMessageId;
 const DmPermissionGate({super.key,required this.id,required this.uid,required this.other,this.initialMessageId});
 Widget chat({bool readOnly=false})=>MessageThread(key:ValueKey(id),collection:db.collection('dms').doc(id).collection('messages'),uid:uid,threadId:'dm:$id',initialMessageId:initialMessageId,readOnly:readOnly);
 @override Widget build(BuildContext c)=>MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(uid).collection('following').doc(other).meowSnapshots(),builder:(c,mine)=>MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(other).collection('following').doc(uid).meowSnapshots(),builder:(c,theirs){
   if(mine.hasError||theirs.hasError)return const Center(child:Text('Não foi possível verificar a amizade.'));
   if(!mine.hasData||!theirs.hasData)return const Center(child:CircularProgressIndicator());
   if(mine.data!.exists&&theirs.data!.exists)return chat();
   return MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('dmRequests').doc(id).meowSnapshots(),builder:(c,request){
     if(request.hasError)return const Center(child:Text('Conversa indisponível.'));
     if(!request.hasData)return const Center(child:CircularProgressIndicator());
     final data=request.data!.data();final status=data?['status'];
     if(status=='declined')return const Center(child:Text('Solicitação recusada.'));
     if(status=='pending'&&data?['to']==uid)return Column(children:[Expanded(child:chat(readOnly:true)),SafeArea(top:false,child:Padding(padding:const EdgeInsets.all(12),child:Column(children:[const Text('Aceite para responder a esta conversa.'),const SizedBox(height:8),Row(children:[Expanded(child:OutlinedButton(onPressed:()async{try{await request.data!.reference.update({'status':'declined'});if(c.mounted)Navigator.maybePop(c);}catch(e){if(c.mounted)notice(c,e);}},child:const Text('Recusar'))),const SizedBox(width:8),Expanded(child:FilledButton(onPressed:()async{try{await request.data!.reference.update({'status':'accepted'});}catch(e){if(c.mounted)notice(c,e);}},child:const Text('Aceitar')))])])))]);
     return chat();
   });
 }));
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
 final uid=FirebaseAuth.instance.currentUser?.uid;if(uid==null)return false;
 final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:Text(resume?'Retomar exclusão?':'Excluir servidor?'),content:Text(resume?'Continuar a limpeza dos dados?':'Esta ação é permanente. O servidor será retirado da lista assim que o backend confirmar o bloqueio. A limpeza dos dados continuará depois.'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancelar')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:Text(resume?'Retomar':'Excluir'))]));
 if(ok!=true||!context.mounted||FirebaseAuth.instance.currentUser?.uid!=uid)return false;
 final result=await showDialog<bool>(context:context,barrierDismissible:false,builder:(_)=>_MeowServerDeleteDialog(id:id,uid:uid));
 if(result==true&&context.mounted)notice(context,'Exclusão iniciada. O servidor não está mais disponível.');
 return result==true;
}
class MeowDeletionQueue {
 static final _running=<String>{};
 static final errors=ValueNotifier<Map<String,String>>({});
 static String key(String uid,String id)=>'$uid/$id';
 static void resume(String uid,String id,{int delay=0}){
  final k=key(uid,id);if(!_running.add(k))return;
  unawaited(_run(uid,id,k,delay));
 }
 static Future<void> _run(String uid,String id,String k,int delay)async{
  try{
   var wait=delay;var failures=0;
   while(FirebaseAuth.instance.currentUser?.uid==uid){
    if(wait>0)await Future<void>.delayed(Duration(milliseconds:wait.clamp(0,180000).toInt()));
    if(FirebaseAuth.instance.currentUser?.uid!=uid)return;
    try{
     final r=await meowServerAction(id,'delete',uid);failures=0;
     if(errors.value.containsKey(k)){final next={...errors.value}..remove(k);errors.value=next;}
     if(r['deleted']==true){PrivateMediaCache.invalidate(mediaUrl('server',id,'avatar'));PrivateMediaCache.invalidate(mediaUrl('server',id,'banner'));return;}
     wait=(r['retryAfterMs'] as int).clamp(500,180000).toInt();
    }catch(e){
     if(FirebaseAuth.instance.currentUser?.uid!=uid)return;
     errors.value={...errors.value,k:e.toString().replaceFirst('Exception: ','')};
     if(++failures>=3)return;wait=3000*failures;
    }
   }
  }finally{_running.remove(k);}
 }
}
class MeowPendingDeletions extends StatelessWidget {
 const MeowPendingDeletions({super.key});
 @override Widget build(BuildContext c)=>MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('servers').where('members',arrayContains:myUid).meowSnapshots(),builder:(c,s){
  final uid=myUid;final pending=(s.data?.docs??[]).where((d)=>d.data()['deleting']==true&&d.data()['ownerId']==uid).toList();
  if(pending.isEmpty)return const SizedBox.shrink();
  return ExpansionTile(leading:const Icon(Icons.delete_outline),title:Text('Exclusões pendentes (${pending.length})'),children:[for(final d in pending)ValueListenableBuilder<Map<String,String>>(valueListenable:MeowDeletionQueue.errors,builder:(c,errors,_)=>ListTile(title:Text(d.data()['name']?.toString()??'Servidor'),subtitle:Text(errors[MeowDeletionQueue.key(uid,d.id)]??'Limpeza dos dados em andamento.'),trailing:TextButton(onPressed:()=>MeowDeletionQueue.resume(uid,d.id),child:const Text('Retomar'))))]);
 });
}
class _MeowServerDeleteDialog extends StatefulWidget {
 final String id,uid;const _MeowServerDeleteDialog({required this.id,required this.uid});
 @override State<_MeowServerDeleteDialog> createState()=>_MeowServerDeleteDialogState();
}
class _MeowServerDeleteDialogState extends State<_MeowServerDeleteDialog>{
 bool busy=true;String? error;
 @override void initState(){super.initState();unawaited(start());}
 Future<void> start()async{
  if(!mounted)return;setState((){busy=true;error=null;});
  try{
   final r=await meowServerAction(widget.id,'delete',widget.uid);
   if(r['deleted']!=true){MeowDeletionQueue.resume(widget.uid,widget.id,delay:r['retryAfterMs'] as int);}else{PrivateMediaCache.invalidate(mediaUrl('server',widget.id,'avatar'));PrivateMediaCache.invalidate(mediaUrl('server',widget.id,'banner'));}
   if(mounted)Navigator.pop(context,true);
  }catch(e){if(mounted)setState((){busy=false;error=e.toString().replaceFirst('Exception: ','');});}
 }
 @override Widget build(BuildContext c)=>PopScope(canPop:!busy,child:AlertDialog(title:const Text('Excluir servidor'),content:busy?const Column(mainAxisSize:MainAxisSize.min,children:[LinearProgressIndicator(),SizedBox(height:12),Text('Confirmando exclusão…')]):Text(error??'Não foi possível confirmar a exclusão.'),actions:[if(!busy)...[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Fechar')),FilledButton(onPressed:start,child:const Text('Tentar novamente'))]]));
}

class ProfileBackground extends StatefulWidget {
 final String uid; const ProfileBackground({super.key,required this.uid});
 @override State<ProfileBackground> createState()=>_ProfileBackgroundState();
}
class _ProfileBackgroundState extends State<ProfileBackground>{
 Future<Uint8List?>? future;String revision='';int epoch=0;bool known=false,profileExists=false;
 StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? sub;
 Timer? retryTimer;int fetchEpoch=0;bool visible=true;Uint8List? lastImage;String? lastOwner;
 void cancelRetry(){retryTimer?.cancel();retryTimer=null;}
 void scheduleRetry(Uri target){cancelRetry();final delay=PrivateMediaCache.retryDelay(target);if(delay==null||!visible)return;retryTimer=Timer(delay,(){if(mounted&&visible&&versionUrl==target){final lifecycle=WidgetsBinding.instance.lifecycleState;if(lifecycle!=null&&lifecycle!=AppLifecycleState.resumed){retryTimer=Timer(const Duration(seconds:30),(){if(mounted)scheduleRetry(target);});return;}setState(()=>future=fetch());}});}
 Future<Uint8List?> fetch()async{cancelRetry();final target=versionUrl;final generation=++fetchEpoch;final owner=FirebaseAuth.instance.currentUser?.uid;if(lastOwner!=owner){lastImage=null;lastOwner=owner;}final bytes=await PrivateMediaCache.get(target);if(!mounted||generation!=fetchEpoch||owner!=FirebaseAuth.instance.currentUser?.uid)return null;final retry=PrivateMediaCache.retryDelay(target);if(bytes!=null)lastImage=bytes;else if(retry==null)lastImage=null;scheduleRetry(target);return bytes??(retry!=null?lastImage:null);}
 Uri get url=>mediaUrl('profile',widget.uid,'background');
 Uri get versionUrl=>revision.isEmpty?url:url.replace(queryParameters:{...url.queryParameters,'revision':revision});
 void refresh(){if(mounted&&known&&changedImage.value==url)setState(()=>future=fetch());}
 void watch(){if(!TickerMode.of(context)){if(sub!=null){epoch++;sub?.cancel();sub=null;}return;}if(sub!=null)return;final generation=++epoch;sub=db.collection('users').doc(widget.uid).meowSnapshots().listen((snap){if(!mounted||generation!=epoch)return;if(!snap.exists&&snap.metadata.isFromCache)return;final next=snap.data()?['backgroundRevision']?.toString()??'';if(!known||next!=revision||snap.exists!=profileExists)setState((){known=true;profileExists=snap.exists;revision=next;if(snap.exists){future=fetch();}else{cancelRetry();fetchEpoch++;lastImage=null;future=Future<Uint8List?>.value(null);}});},onError:(Object _){if(mounted&&generation==epoch&&!known&&future==null)setState(()=>future=fetch());});}
 @override void initState(){super.initState();changedImage.addListener(refresh);}
 @override void didChangeDependencies(){super.didChangeDependencies();visible=TickerMode.of(context);if(!visible)cancelRetry();watch();if(visible&&future!=null&&PrivateMediaCache.retryDelay(versionUrl)!=null)scheduleRetry(versionUrl);}
 @override void didUpdateWidget(covariant ProfileBackground old){super.didUpdateWidget(old);if(old.uid!=widget.uid){cancelRetry();fetchEpoch++;lastImage=null;lastOwner=null;epoch++;sub?.cancel();sub=null;revision='';known=false;profileExists=false;future=null;watch();}}
 @override void dispose(){cancelRetry();fetchEpoch++;epoch++;sub?.cancel();changedImage.removeListener(refresh);super.dispose();}
 @override Widget build(BuildContext c)=>FutureBuilder<Uint8List?>(key:ValueKey(url),future:future,builder:(c,s)=>s.data==null?const SizedBox.shrink():Stack(fit:StackFit.expand,children:[meowPreview(c,s.data!,width:0,height:0,fit:BoxFit.cover,errorBuilder:(c,e,st)=>const SizedBox.shrink()),const ColoredBox(color:Color(0x99000000))]));
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
 @override Widget build(BuildContext c){final n=widget.size??(widget.data['kind']=='sticker'?144.0:30.0);return SizedBox(width:n,height:n,child:FutureBuilder<Uint8List?>(future:future,builder:(c,s)=>s.data==null?const Icon(Icons.image_outlined):meowPreview(c,s.data!,width:n,height:n,fit:BoxFit.contain,errorBuilder:(c,e,st)=>const Icon(Icons.broken_image))));}
}
// 0.8.1: a bounded, explicit dark sheet. Load the catalogue independently
// of hidden-tab TickerMode and keep one shared future for both custom tabs.
Future<Object?> pickExpression(BuildContext context,{bool reactionOnly=false})=>
 showModalBottomSheet<Object>(context:context,isScrollControlled:true,backgroundColor:panel,
   builder:(c)=>SafeArea(top:false,child:SizedBox(
     height:min(540.0,max(180.0,(MediaQuery.sizeOf(c).height-MediaQuery.viewInsetsOf(c).bottom)*.72)),
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
 final search=TextEditingController();List<String> recent=[];
 @override void dispose(){search.dispose();super.dispose();}
 Future<void> loadRecent()async{final prefs=await SharedPreferences.getInstance();if(mounted)setState(()=>recent=prefs.getStringList('meow.emoji.recent.${widget.uid}')??[]);}
 void chooseEmoji(BuildContext c,String e){final updated=[e,...recent.where((x)=>x!=e)].take(32).toList();unawaited(SharedPreferences.getInstance().then((p)=>p.setStringList('meow.emoji.recent.${widget.uid}',updated)).then<void>((_){}).catchError((Object _){}));Navigator.pop(c,e);}
 bool matchesExpression(Map<String,dynamic> d)=>search.text.trim().isEmpty||(d['name']?.toString()??'').toLowerCase().contains(search.text.trim().toLowerCase());
 @override void initState(){super.initState();catalog=load();unawaited(loadRecent());}
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
   final visible=groups.where((g)=>g.failed||g.items.any((item)=>item.data()['kind']==kind&&matchesExpression(item.data()))).toList();
   if(visible.isEmpty)return emptyOrError(kind=='emoji'?'Nenhum emoji personalizado disponível.':'Nenhuma figurinha disponível.');
   return ListView.builder(padding:const EdgeInsets.fromLTRB(12,8,12,16),itemCount:visible.length,itemBuilder:(c,index){
     final group=visible[index];
     return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
       ListTile(contentPadding:EdgeInsets.zero,title:Text(group.name,maxLines:1,overflow:TextOverflow.ellipsis)),
       if(group.failed)ListTile(contentPadding:EdgeInsets.zero,title:const Text('Não foi possível carregar este servidor.'),
         trailing:IconButton(tooltip:'Tentar novamente',onPressed:retry,icon:const Icon(Icons.refresh)))
       else Wrap(spacing:4,runSpacing:4,children:[
         for(final item in group.items.where((d)=>d.data()['kind']==kind&&matchesExpression(d.data())))
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
 Widget standard(){final q=search.text.trim().toLowerCase();const labels=['sorriso feliz','risada chorar','amor paixão','choro triste','óculos legal','amor carinho','raiva','pensar dúvida','dormir sono','gato feliz','coração vermelho','coração roxo','joinha sim','não negativo','fogo','festa comemoração','brilho','caveira','olhos','oração obrigado','gato','cachorro','flor','pizza','jogo','cem'];final shown=<String>[for(var i=0;i<meowEmojis.length;i++)if(q.isEmpty||meowEmojis[i].contains(q)||(i<labels.length&&labels[i].contains(q)))meowEmojis[i]];
  Widget grid(List<String> items)=>Wrap(spacing:4,runSpacing:4,children:[for(final e in items)SizedBox(width:42,height:42,child:InkWell(onTap:()=>chooseEmoji(context,e),child:Center(child:Text(e,style:const TextStyle(fontSize:30)))))]);
  return ListView(padding:const EdgeInsets.all(12),children:[if(q.isEmpty&&recent.isNotEmpty)...[const Text('Utilizados com frequência',style:TextStyle(fontWeight:FontWeight.bold)),const SizedBox(height:8),grid(recent),const SizedBox(height:16)],const Text('Emojis',style:TextStyle(fontWeight:FontWeight.bold)),const SizedBox(height:8),grid(shown),const SizedBox(height:12),const Text('Emojis dos servidores',style:TextStyle(fontWeight:FontWeight.bold)),SizedBox(height:280,child:custom('emoji'))]);}
 @override Widget build(BuildContext c)=>Material(color:panel,child:DefaultTabController(length:widget.reactionOnly?1:2,child:Column(children:[
  const SizedBox(height:8),Container(height:4,width:36,decoration:BoxDecoration(color:Colors.white38,borderRadius:BorderRadius.circular(3))),const SizedBox(height:8),
  Padding(padding:const EdgeInsets.symmetric(horizontal:10),child:TabBar(tabs:[const Tab(text:'Emoji'),if(!widget.reactionOnly)const Tab(text:'Figurinhas')])),
  Padding(padding:const EdgeInsets.all(10),child:TextField(controller:search,onChanged:(_)=>setState((){}),decoration:const InputDecoration(prefixIcon:Icon(Icons.search),hintText:'Pesquisar emojis e figurinhas'))),
  Expanded(child:TabBarView(children:[standard(),if(!widget.reactionOnly)custom('sticker')])),
 ])));
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
String fileSizeLabel(int n,{bool preferMB=false}) {
  if(n>=1000000000000)return '${(n/1000000000000).toStringAsFixed(1)} TB';
  if(n>=1000000000)return '${(n/1000000000).toStringAsFixed(1)} GB';
  if(n>=1000000||preferMB)return '${(n/1000000).toStringAsFixed(1)} MB';
  if(n>=1000)return '${(n/1000).toStringAsFixed(1)} KB';
  return '$n B';
}
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
Future<void> showMeowMembers(BuildContext context,String server)async{
 FocusManager.instance.primaryFocus?.unfocus();
 await showGeneralDialog<void>(context:context,barrierDismissible:true,barrierLabel:'Membros',transitionDuration:const Duration(milliseconds:220),pageBuilder:(c,_,__)=>Align(alignment:Alignment.centerRight,child:Material(color:panel,child:SizedBox(width:min(MediaQuery.sizeOf(c).width*.85,350.0),child:GestureDetector(behavior:HitTestBehavior.opaque,onHorizontalDragEnd:(d){if((d.primaryVelocity??0)>200)Navigator.pop(c);},child:ServerMembers(server:server))))),transitionBuilder:(c,a,_,child)=>SlideTransition(position:Tween(begin:const Offset(1,0),end:Offset.zero).animate(a),child:child));
}
class MeowEdgeSwipe extends StatefulWidget{
 final VoidCallback onOpen;const MeowEdgeSwipe({super.key,required this.onOpen});
 @override State<MeowEdgeSwipe> createState()=>_MeowEdgeSwipeState();
}
class _MeowEdgeSwipeState extends State<MeowEdgeSwipe>{
 double dx=0;
 @override Widget build(BuildContext c)=>GestureDetector(behavior:HitTestBehavior.translucent,onHorizontalDragStart:(_)=>dx=0,onHorizontalDragUpdate:(d)=>dx+=d.primaryDelta??0,onHorizontalDragEnd:(d){if(dx< -45||(d.primaryVelocity??0)< -300)widget.onOpen();},child:const SizedBox.expand());
}
class ServerMembers extends StatefulWidget {
 final String server;const ServerMembers({super.key,required this.server});
 @override State<ServerMembers> createState()=>_ServerMembersState();
}
class _ServerMembersState extends State<ServerMembers>{
 final users=<String,Map<String,dynamic>>{};final subs=<String,StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>>{};StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? serverSub;Timer? timer;
 @override void initState(){super.initState();serverSub=db.collection('servers').doc(widget.server).meowSnapshots().listen((s){if(!mounted)return;final ids=List<String>.from(s.data()?['members']??[]).toSet();for(final id in subs.keys.toList()){if(!ids.contains(id)){subs.remove(id)?.cancel();users.remove(id);}}for(final id in ids){users.putIfAbsent(id,()=>{});subs.putIfAbsent(id,()=>db.collection('users').doc(id).meowSnapshots().listen((u){if(mounted)setState(()=>users[id]=u.data()??{});}));}setState((){});});timer=Timer.periodic(const Duration(seconds:5),(_){if(mounted)setState((){});});}
 @override void dispose(){timer?.cancel();serverSub?.cancel();for(final s in subs.values){s.cancel();}super.dispose();}
 @override Widget build(BuildContext c){final online=users.entries.where((e)=>currentPresence(e.value)!='offline').toList()..sort((a,b)=>userLabel(a.value).compareTo(userLabel(b.value)));final offline=users.entries.where((e)=>currentPresence(e.value)=='offline').toList()..sort((a,b)=>userLabel(a.value).compareTo(userLabel(b.value)));return SafeArea(child:Column(children:[ListTile(title:const Text('Membros',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),trailing:IconButton(onPressed:()=>Navigator.pop(c),icon:const Icon(Icons.close))),Expanded(child:ListView(children:[for(final group in [online,offline])...[Padding(padding:const EdgeInsets.all(12),child:Text('${identical(group,online)?'ONLINE':'OFFLINE'} — ${group.length}',style:const TextStyle(fontSize:12,color:Colors.white70))),for(final e in group)ListTile(leading:ProfileAvatar(uid:e.key),title:Text(userLabel(e.value)),dense:false,visualDensity:VisualDensity.standard,contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:5),onTap:()=>openProfile(c,e.key))]]))]));}
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
 final bool open;final ValueChanged<bool> onChange;final Widget list,chat;final VoidCallback? onMembers;const ChannelSlide({super.key,required this.open,required this.onChange,required this.list,required this.chat,this.onMembers});
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
     if(!widget.open&&widget.onMembers!=null)Positioned(right:0,top:48,bottom:0,width:22,child:MeowEdgeSwipe(onOpen:widget.onMembers!)),
   ]));
 });
}
class ReplySwipe extends StatefulWidget {
 final Widget child;final VoidCallback onReply;const ReplySwipe({super.key,required this.child,required this.onReply});
 @override State<ReplySwipe> createState()=>_ReplySwipeState();
}
class _ReplySwipeState extends State<ReplySwipe>{double x=0;bool dragging=false,haptic=false;@override Widget build(BuildContext c)=>GestureDetector(onHorizontalDragStart:(_){setState(()=>dragging=true);},onHorizontalDragUpdate:(d){setState(()=>x=(x+(d.primaryDelta??0)*.65).clamp(0.0,90.0).toDouble());if(x>=55&&!haptic){haptic=true;HapticFeedback.selectionClick();}},onHorizontalDragEnd:(_){if(x>=55)widget.onReply();setState((){x=0;dragging=false;haptic=false;});},onHorizontalDragCancel:()=>setState((){x=0;dragging=false;haptic=false;}),child:Stack(alignment:Alignment.centerLeft,children:[if(x>5)Padding(padding:const EdgeInsets.only(left:8),child:Icon(Icons.reply,color:x>=55?purple:Colors.white54)),AnimatedContainer(duration:dragging?Duration.zero:const Duration(milliseconds:160),transform:Matrix4.translationValues(x,0,0),child:widget.child)]));}
// Discord-style display formatting. Original text is retained for edits, copies and Firestore.
class MeowMessageText extends StatelessWidget {
 final String text;final Map<String,Map<String,dynamic>> people;final bool compact;
 const MeowMessageText({super.key,required this.text,required this.people,this.compact=false});
 static final _emojiPattern=RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}]',unicode:true);
 bool emoji(String c)=>_emojiPattern.hasMatch(c);
 static bool isEmojiOnly(String value){final gs=value.characters.where((g)=>g.trim().isNotEmpty).toList();return gs.isNotEmpty&&gs.every((g)=>_emojiPattern.hasMatch(g));}
 static const _markers=['__***','__**','__*','***','**','__','~~','*','_'];
 static final _customLink=RegExp(r'\[([^\]\n]+)\]\((https?://[^\s)]+)\)');
 static final _rawLink=RegExp(r'https?://[^\s<>]+');
 static final _wordChar=RegExp(r'[A-Za-z0-9]');
 String closing(String marker)=>switch(marker){'__***'=>'***__','__**'=>'**__','__*'=>'*__',_=>marker};
 TextStyle decorationFor(String marker,TextStyle base){
  final decorations=<TextDecoration>[if(base.decoration!=null)base.decoration!,if(marker.startsWith('__'))TextDecoration.underline,if(marker=='~~')TextDecoration.lineThrough];
  return base.copyWith(fontWeight:marker.contains('**')?FontWeight.bold:base.fontWeight,fontStyle:marker=='_'||marker=='*'||marker.endsWith('***')||marker=='__*'?FontStyle.italic:base.fontStyle,decoration:decorations.isEmpty?null:TextDecoration.combine(decorations));
 }
 int findClose(String source,String delimiter,int start){
  var i=start;
  while(i<source.length){
   final pos=source.indexOf(delimiter,i);if(pos<0)return -1;
   var slashes=0;for(var j=pos-1;j>=0&&source[j]=='\\';j--){slashes++;}
   final exactCode=delimiter.startsWith('`');
   if((exactCode||slashes.isEven)&&(!exactCode||((pos==0||source[pos-1]!='`')&&(pos+delimiter.length==source.length||source[pos+delimiter.length]!='`'))))return pos;
   i=pos+1;
  }
  return -1;
 }
 // Scan nested delimiters before testing the enclosing close. Treat an
 // unmatched run as a literal run rather than parsing its suffix separately.
 String? markerAt(String source,int i){
  for(final marker in _markers){
   if(!source.startsWith(marker,i))continue;
   if(marker=='_'&&i>0&&_wordChar.hasMatch(source[i-1]))continue;
   final start=i+marker.length;if(start>=source.length||source[start].trim().isEmpty)continue;
   if(source[start]==marker[0]&&marker.split('').every((ch)=>ch==marker[0]))continue;
   return marker;
  }
  return null;
 }
 int formatEnd(String source,String marker,int start,{String? parentClose,int depth=0,List<int>? budget}){
  if(depth>12)return -1;
  final remaining=budget??[12000];
  final close=closing(marker);var i=start;
  while(i<source.length){
   if(--remaining[0]<0)return -1;
   if(source[i]=='\\'&&i+1<source.length){i+=2;continue;}
   if(source[i]=='`'){
    var n=1;while(i+n<source.length&&source[i+n]=='`')n++;
    final end=findClose(source,source.substring(i,i+n),i+n);
    if(end>=0){i=end+n;continue;}i+=n;continue;
   }
   if(source.startsWith(close,i)&&i>start&&source[i-1].trim().isNotEmpty){
    var run=0;while(i+run<source.length&&source[i+run]==close[0])run++;
    final uniform=close.split('').every((ch)=>ch==close[0]);
    final parentRun=parentClose!=null&&parentClose.split('').every((ch)=>ch==close[0])?parentClose.length:0;
    if(!uniform||run==close.length||(parentRun>0&&run==close.length+parentRun))return i;
   }
   final inner=markerAt(source,i);
   if(inner!=null){final end=formatEnd(source,inner,i+inner.length,parentClose:close,depth:depth+1,budget:remaining);if(end>=0){i=end+closing(inner).length;continue;}}
   if('*_~'.contains(source[i])){final ch=source[i];do{i++;}while(i<source.length&&source[i]==ch);}else{i++;}
  }
  return -1;
 }
 Future<void> openLink(BuildContext c,String url)async{
  final uri=Uri.tryParse(url);
  if(uri==null||!['https','http'].contains(uri.scheme.toLowerCase())||uri.host.isEmpty){notice(c,'Endereço inválido.');return;}
  final ok=await showDialog<bool>(context:c,builder:(d)=>AlertDialog(title:const Text('Abrir link externo?'),content:SelectableText(uri.toString()),actions:[TextButton(onPressed:()=>Navigator.pop(d,false),child:const Text('Cancelar')),FilledButton(onPressed:()=>Navigator.pop(d,true),child:const Text('Abrir'))]));
  if(ok!=true||!c.mounted)return;
  try{if(!await launchUrl(uri,mode:LaunchMode.externalApplication)&&c.mounted)notice(c,'Não foi possível abrir o link.');}catch(_){if(c.mounted)notice(c,'Não foi possível abrir o link.');}
 }
 List<InlineSpan> inline(BuildContext c,String source,TextStyle style,{int depth=0}){
  if(depth>12)return [TextSpan(text:source,style:style)];
  final out=<InlineSpan>[];var buffer=StringBuffer();
  void flush(){if(buffer.isEmpty)return;final str=buffer.toString();buffer=StringBuffer();if(compact||!_emojiPattern.hasMatch(str)){out.add(TextSpan(text:str,style:style));return;}
   var current=StringBuffer();bool? large;void add(){if(current.isEmpty)return;out.add(TextSpan(text:current.toString(),style:large==true?style.copyWith(fontSize:style.fontSize??16):style));current=StringBuffer();}
   for(final g in str.characters){final next=emoji(g);if(large!=null&&large!=next)add();large=next;current.write(g);}add();
  }
  var i=0;
  while(i<source.length){
   if(source[i]=='\\'&&i+1<source.length&&r'\*_~`|#>[]().-!+'.contains(source[i+1])){buffer.write(source[i+1]);i+=2;continue;}
   if(source[i]=='`'){
    var n=1;while(i+n<source.length&&source[i+n]=='`')n++;
    final delim=source.substring(i,i+n),end=findClose(source,delim,i+n);
    if(end>i+n){flush();out.add(TextSpan(text:source.substring(i+n,end),style:style.copyWith(fontFamily:'monospace',backgroundColor:const Color(0xFF303036),color:style.color??Colors.white)));i=end+n;continue;}
   }
   if(source.startsWith('||',i)){
    final end=findClose(source,'||',i+2);if(end>i+2){flush();final content=source.substring(i+2,end);if(compact){out.add(TextSpan(text:'[spoiler]',style:style));}else{out.add(WidgetSpan(alignment:PlaceholderAlignment.middle,child:MeowSpoiler(key:ValueKey('$i:$content'),child:Text.rich(TextSpan(children:inline(c,content,style,depth:depth+1))))));}i=end+2;continue;}
   }
   if(source.startsWith('<http',i)){
    final end=source.indexOf('>',i+1);if(end>i){final url=source.substring(i+1,end);if(_rawLink.stringMatch(url)==url){flush();final linkStyle=style.copyWith(color:const Color(0xFF93C5FD),decoration:TextDecoration.underline);if(compact){out.add(TextSpan(text:url,style:linkStyle));}else{out.add(WidgetSpan(alignment:PlaceholderAlignment.middle,child:InkWell(onTap:()=>openLink(c,url),child:Text(url,style:linkStyle))));}i=end+1;continue;}}
   }
   final link=_customLink.matchAsPrefix(source,i);
   final raw=_rawLink.matchAsPrefix(source,i);
   if(link!=null||raw!=null){
    final match=link??raw!;final label=link?.group(1)??match.group(0)!;var url=link?.group(2)??label;var suffix='';
    if(link==null){while(url.isNotEmpty&&'.,;:!?)]'.contains(url[url.length-1])){suffix=url[url.length-1]+suffix;url=url.substring(0,url.length-1);}}
    if(url.isNotEmpty){flush();final title=link==null?url:label;final dest=url;final linkStyle=style.copyWith(color:const Color(0xFF93C5FD),decoration:TextDecoration.underline);
     if(compact){out.add(TextSpan(text:title,style:linkStyle));}else{out.add(WidgetSpan(alignment:PlaceholderAlignment.middle,child:InkWell(onTap:()=>openLink(c,dest),child:Text(title,style:linkStyle))));}
     if(suffix.isNotEmpty)out.add(TextSpan(text:suffix,style:style));i=match.end;continue;
    }
   }
   final mention=_meowMentionPattern.matchAsPrefix(source,i);
   if(mention!=null){
    flush();final name=mention.group(1)!.toLowerCase();final found=people.entries.where((e)=>meowSerial(e.value).isNotEmpty&&name=='#${meowSerial(e.value)}');
    if(found.isNotEmpty){final person=found.first;final title='@${userLabel(person.value)}';final mentionStyle=style.copyWith(color:const Color(0xFFC4B5FD),fontWeight:FontWeight.w600,backgroundColor:purple.withOpacity(.18));if(compact){out.add(TextSpan(text:title,style:mentionStyle));}else{out.add(WidgetSpan(alignment:PlaceholderAlignment.middle,child:InkWell(onTap:()=>openProfile(c,person.key),child:Text(title,style:mentionStyle))));}}
    else{out.add(TextSpan(text:mention.group(0),style:name=='everyone'?style.copyWith(color:const Color(0xFFC4B5FD)):style));}
    i=mention.end;continue;
   }
   final marker=markerAt(source,i);
   if(marker!=null){
    final start=i+marker.length, end=formatEnd(source,marker,i+marker.length);
    if(end>start){flush();out.addAll(inline(c,source.substring(start,end),decorationFor(marker,style),depth:depth+1));i=end+closing(marker).length;continue;}
    // Preserve malformed formatting verbatim; no partial consumption of ***.
    buffer.write(marker);i+=marker.length;continue;
   }
   if('*_~'.contains(source[i])){final ch=source[i];do{buffer.write(source[i]);i++;}while(i<source.length&&source[i]==ch);continue;}
   buffer.write(source[i]);i++;
  }
  flush();return out;
 }
 Widget rich(BuildContext c,String source,TextStyle style)=>LayoutBuilder(builder:(c,b){
  final width=b.hasBoundedWidth?b.maxWidth:MediaQuery.sizeOf(c).width-48;
  final spans=inline(c,source,style).map<InlineSpan>((span)=>span is WidgetSpan?WidgetSpan(alignment:span.alignment,baseline:span.baseline,child:ConstrainedBox(constraints:BoxConstraints(maxWidth:max(1.0,width)),child:span.child)):span).toList();
  return Text.rich(TextSpan(children:spans),maxLines:compact?2:null,softWrap:true,overflow:compact?TextOverflow.ellipsis:TextOverflow.clip);
 });
 Widget quote(BuildContext c,String content,TextStyle style)=>Container(margin:const EdgeInsets.symmetric(vertical:3),padding:const EdgeInsets.only(left:9),decoration:const BoxDecoration(border:Border(left:BorderSide(width:3,color:Colors.white38))),child:rich(c,content,style));
 @override Widget build(BuildContext c){
  final style=DefaultTextStyle.of(c).style;
  if(compact)return rich(c,text.replaceAll('\n',' '),style);
  final graphemes=text.characters.where((g)=>g.trim().isNotEmpty).toList();
  if(graphemes.isNotEmpty&&graphemes.length<=5&&graphemes.every(emoji))return Text(text,style:style.copyWith(fontSize:graphemes.length==1?30:graphemes.length<=3?25:22));
  final lines=text.replaceAll('\r\n','\n').split('\n');final blocks=<Widget>[];final plain=<String>[];
  void flush(){if(plain.isEmpty)return;blocks.add(rich(c,plain.join('\n'),style));plain.clear();}
  var i=0;
  while(i<lines.length){
   final line=lines[i];
   if(line.startsWith('```')){
    final first=line.substring(3);final same=first.indexOf('```');
    if(same>=0){flush();blocks.add(MeowCodeBlock(code:first.substring(0,same),language:''));final remainder=first.substring(same+3);if(remainder.isNotEmpty)plain.add(remainder);i++;continue;}
    var end=i+1;while(end<lines.length&&!lines[end].startsWith('```'))end++;
    if(end<lines.length){flush();final lang=RegExp(r'^[\w+.#-]{0,24}$').hasMatch(first.trim())?first.trim():'';final code=[if(lang.isEmpty&&first.isNotEmpty)first,...lines.sublist(i+1,end)].join('\n');blocks.add(MeowCodeBlock(code:code,language:lang));final remainder=lines[end].substring(3);if(remainder.isNotEmpty)plain.add(remainder);i=end+1;continue;}
   }
   final heading=RegExp(r'^(#{1,3}|-#)\s+(.+)$').firstMatch(line);
   if(heading!=null){flush();final marker=heading.group(1)!;final size=marker=='#'?24.0:marker=='##'?20.0:marker=='###'?17.0:12.0;blocks.add(Padding(padding:const EdgeInsets.symmetric(vertical:2),child:rich(c,heading.group(2)!,style.copyWith(fontSize:size,fontWeight:marker=='-#'?FontWeight.normal:FontWeight.bold,color:marker=='-#'?style.color?.withOpacity(.7):style.color))));i++;continue;}
   if(line.startsWith('>>> ')){flush();blocks.add(quote(c,[line.substring(4),...lines.skip(i+1)].join('\n'),style));break;}
   if(line.startsWith('> ')){flush();final q=<String>[];while(i<lines.length&&lines[i].startsWith('> ')){q.add(lines[i].substring(2));i++;}blocks.add(quote(c,q.join('\n'),style));continue;}
   final list=RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.+)$').firstMatch(line);
   if(list!=null){flush();final indent=min(4,list.group(1)!.replaceAll('\t','  ').length~/2);final marker=list.group(2)!;blocks.add(Padding(padding:EdgeInsets.only(left:indent*12.0,top:1,bottom:1),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(RegExp(r'^\d').hasMatch(marker)?'$marker ':'• ',style:style),Expanded(child:rich(c,list.group(3)!,style))])));i++;continue;}
   plain.add(line);i++;
  }
  flush();if(blocks.isEmpty)return Text(text,style:style);if(blocks.length==1)return blocks.first;return LayoutBuilder(builder:(c,b)=>ConstrainedBox(constraints:BoxConstraints(maxWidth:b.hasBoundedWidth?b.maxWidth:max(1.0,MediaQuery.sizeOf(c).width-48)),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:blocks)));
 }
}
class MeowSpoiler extends StatefulWidget {
 final Widget child;const MeowSpoiler({super.key,required this.child});
 @override State<MeowSpoiler> createState()=>_MeowSpoilerState();
}
class _MeowSpoilerState extends State<MeowSpoiler>{
 bool visible=false;
 @override Widget build(BuildContext c)=>GestureDetector(onTap:()=>setState(()=>visible=!visible),child:Semantics(button:true,label:visible?'Ocultar spoiler':'Revelar spoiler',child:Container(padding:const EdgeInsets.symmetric(horizontal:4,vertical:1),decoration:BoxDecoration(color:visible?Colors.white12:const Color(0xFF55555E),borderRadius:BorderRadius.circular(4)),child:visible?widget.child:Stack(children:[ExcludeSemantics(child:Opacity(opacity:0,child:IgnorePointer(child:widget.child))),const Positioned.fill(child:Center(child:Text('Spoiler',style:TextStyle(fontSize:11,color:Colors.white70))))]))));
}
class MeowCodeBlock extends StatelessWidget {
 final String code,language;const MeowCodeBlock({super.key,required this.code,required this.language});
 List<InlineSpan> highlighted(){
  const base=TextStyle(fontFamily:'monospace',fontSize:13,color:Color(0xFFE4E4E7));
  if(language.isEmpty)return [TextSpan(text:code,style:base)];
  final pattern=RegExp(r'''(//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:class|return|if|else|while|for|def|function|const|let|var|final|import|from|async|await|true|false|null|new|void|int|String|print|public|private|try|catch|throw|switch|case|break|continue)\b|\b\d+(?:\.\d+)?\b)''');
  final spans=<InlineSpan>[];var last=0;
  for(final m in pattern.allMatches(code)){if(m.start>last)spans.add(TextSpan(text:code.substring(last,m.start),style:base));final token=m.group(0)!;final color=token.startsWith('//')||token.startsWith('/*')||token.startsWith('#')?const Color(0xFF91A399):token.startsWith('"')||token.startsWith("'")?const Color(0xFFB7E3A1):RegExp(r'^\d').hasMatch(token)?const Color(0xFFF5C78B):const Color(0xFFC4B5FD);spans.add(TextSpan(text:token,style:base.copyWith(color:color)));last=m.end;}
  if(last<code.length)spans.add(TextSpan(text:code.substring(last),style:base));return spans;
 }
 @override Widget build(BuildContext c)=>LayoutBuilder(builder:(c,b)=>ConstrainedBox(constraints:BoxConstraints(maxWidth:b.hasBoundedWidth?b.maxWidth:max(1.0,MediaQuery.sizeOf(c).width-72)),child:Container(margin:const EdgeInsets.symmetric(vertical:4),decoration:BoxDecoration(color:const Color(0xFF16161D),borderRadius:BorderRadius.circular(8),border:Border.all(color:Colors.white12)),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[Expanded(child:Padding(padding:const EdgeInsets.only(left:10),child:Text(language.isEmpty?'Código':language,style:const TextStyle(fontSize:11,color:Colors.white54)))),IconButton(tooltip:'Copiar código',visualDensity:VisualDensity.compact,onPressed:()async{await Clipboard.setData(ClipboardData(text:code));if(c.mounted)notice(c,'Código copiado.');},icon:const Icon(Icons.copy,size:16))]),const Divider(height:1),SingleChildScrollView(scrollDirection:Axis.horizontal,padding:const EdgeInsets.all(10),child:Text.rich(TextSpan(children:highlighted())))]))));
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
 final Uint8List bytes;final double aspect;final bool circle,showAvatarGuide;const MeowCropPage({super.key,required this.bytes,required this.aspect,required this.circle,this.showAvatarGuide=false});
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
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Ajustar imagem'),actions:[TextButton(onPressed:busy?null:()=>Navigator.pop(c,widget.bytes),child:const Text('Pular')),IconButton(tooltip:'Confirmar recorte',onPressed:busy||image==null?null:confirm,icon:const Icon(Icons.check))]),body:Column(children:[Expanded(child:Center(child:LayoutBuilder(builder:(c,b){if(image==null)return const Text('Carregando imagem…');final w=min(b.maxWidth-24,(b.maxHeight-24)*widget.aspect);frame=Size(max(1.0,w),max(1.0,w/widget.aspect));return GestureDetector(onScaleStart:(d){startZoom=zoom;startOffset=offset;startPoint=d.localFocalPoint;},onScaleUpdate:(d)=>setState((){zoom=(startZoom*d.scale).clamp(1.0,6.0).toDouble();offset=bounded(startOffset+d.localFocalPoint-startPoint);}),child:ClipRRect(borderRadius:BorderRadius.circular(widget.circle?frame.width/2:8),child:Stack(children:[CustomPaint(size:frame,painter:CropPainter(image!,turns,baseScale()*zoom,offset)),if(widget.showAvatarGuide)Positioned(left:frame.width*.37,bottom:-frame.width*.13,width:frame.width*.26,height:frame.width*.26,child:IgnorePointer(child:DecoratedBox(decoration:BoxDecoration(shape:BoxShape.circle,color:Colors.black26,border:Border.all(color:Colors.white70,width:2)))))])));}))),const Text('Arraste e use dois dedos para aproximar'),Slider(value:zoom,min:1,max:6,onChanged:image==null?null:(v)=>setState((){zoom=v;offset=bounded(offset);})),SafeArea(top:false,child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[IconButton(tooltip:'Girar',onPressed:busy||image==null?null:()=>setState((){turns=(turns+1)%4;zoom=1;offset=Offset.zero;}),icon:const Icon(Icons.rotate_right)),TextButton(onPressed:busy?null:()=>Navigator.pop(c),child:const Text('Cancelar')),FilledButton(onPressed:busy||image==null?null:confirm,child:const Text('Confirmar'))]))]));
}
void paintCrop(Canvas c,Size size,ui.Image image,int turns,double scale,Offset offset){c.save();c.clipRect(Offset.zero&size);c.translate(size.width/2+offset.dx,size.height/2+offset.dy);c.rotate(turns*pi/2);c.scale(scale);c.drawImage(image,Offset(-image.width/2,-image.height/2),Paint()..filterQuality=FilterQuality.high);c.restore();}
class CropPainter extends CustomPainter{final ui.Image image;final int turns;final double scale;final Offset offset;CropPainter(this.image,this.turns,this.scale,this.offset);@override void paint(Canvas canvas,Size size)=>paintCrop(canvas,size,image,turns,scale,offset);@override bool shouldRepaint(covariant CropPainter old)=>old.image!=image||old.turns!=turns||old.scale!=scale||old.offset!=offset;}


// Meow 0.9.0 — navigation and profile presentation (first development stage).
class MeowAccountHeader extends StatelessWidget {
 final String uid;final VoidCallback? onTap;final bool showPresence;
 const MeowAccountHeader({super.key,required this.uid,this.onTap,this.showPresence=false});
 @override Widget build(BuildContext c)=>InkWell(onTap:onTap,child:MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('users').doc(uid).meowSnapshots(),builder:(c,s){
  final d=s.data?.data()??{};final presence=currentPresence(d);
  return Row(children:[Stack(clipBehavior:Clip.none,children:[PrivateImage(scope:'profile',id:uid,slot:'avatar',size:38),Positioned(bottom:0,right:0,child:PresenceDot(uid:uid))]),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisSize:MainAxisSize.min,children:[Text(userLabel(d),maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:16,fontWeight:FontWeight.bold)),if(showPresence)Text(presenceLabels[presence]??'Offline',style:const TextStyle(fontSize:12,color:Colors.white54),maxLines:1,overflow:TextOverflow.ellipsis)]))]);
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
   Positioned(left:16,right:16,bottom:14,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[PrivateImage(scope:'profile',id:uid,slot:'avatar',size:66),const SizedBox(height:8),Text(userLabel(d),style:const TextStyle(fontSize:22,fontWeight:FontWeight.bold,color:Colors.white))])),
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
class MeowUnreadMark extends StatelessWidget{
 final bool unread;const MeowUnreadMark({super.key,required this.unread});
 @override Widget build(BuildContext c)=>SizedBox(width:10,height:10,child:unread?Semantics(label:'Mensagens não lidas',child:const DecoratedBox(decoration:BoxDecoration(color:Color(0xFF39F57A),shape:BoxShape.circle))):null);
}
class _SectionThread {
 final CollectionReference<Map<String,dynamic>> collection;
 StreamSubscription<QuerySnapshot<Map<String,dynamic>>>? messages;
 StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? receipt;
 List<QueryDocumentSnapshot<Map<String,dynamic>>> items=[];Timestamp? seen;bool receiptReady=false;
 _SectionThread(this.collection);
 bool unread(String uid)=>receiptReady&&items.any((d){final m=d.data();final t=m['createdAt'];return m['authorId']!=uid&&t is Timestamp&&(seen==null||t.compareTo(seen!)>0);});
 void close(){messages?.cancel();receipt?.cancel();}
}
class MeowSectionUnread extends StatefulWidget{
 final String uid;final bool servers;const MeowSectionUnread({super.key,required this.uid,required this.servers});
 @override State<MeowSectionUnread> createState()=>_MeowSectionUnreadState();
}
class _MeowSectionUnreadState extends State<MeowSectionUnread>{
 StreamSubscription<QuerySnapshot<Map<String,dynamic>>>? root;
 final channels=<String,StreamSubscription<QuerySnapshot<Map<String,dynamic>>>>{};
 final threads=<String,_SectionThread>{};
 int epoch=0;bool queued=false,unread=false;
 void refresh(){if(queued)return;queued=true;WidgetsBinding.instance.addPostFrameCallback((_){queued=false;if(!mounted)return;final next=threads.values.any((t)=>t.unread(widget.uid));if(next!=unread)setState(()=>unread=next);});WidgetsBinding.instance.ensureVisualUpdate();}
 void drop(String id){threads.remove(id)?.close();}
 void watchThread(String id,CollectionReference<Map<String,dynamic>> collection){
   if(threads.containsKey(id))return;final t=_SectionThread(collection);threads[id]=t;final generation=epoch;
   bool valid()=>mounted&&generation==epoch&&identical(threads[id],t);
   t.receipt=receiptRef(id,widget.uid).meowSnapshots().listen((s){if(!valid())return;final value=s.data()?['at'];t.seen=value is Timestamp?value:null;t.receiptReady=true;refresh();},onError:(Object _){if(valid()){t.receiptReady=false;refresh();}});
   // Share identical query with the chat list and server unread indicators.
   t.messages=collection.orderBy('createdAt',descending:true).limit(100).meowSnapshots().listen((s){if(valid()){t.items=s.docs;refresh();}},onError:(Object _){if(valid()){t.items=[];refresh();}});
 }
 void removeServer(String id){channels.remove(id)?.cancel();for(final key in threads.keys.where((k)=>k.startsWith('server:$id:')).toList()){drop(key);}}
 void resume(){if(root!=null)return;final generation=++epoch;
   root=db.collection(widget.servers?'servers':'dms').where('members',arrayContains:widget.uid).meowSnapshots().listen((s){
     if(!mounted||generation!=epoch)return;
     final docs=s.docs.where((d)=>d.data()['deleting']!=true).toList();final ids=docs.map((d)=>d.id).toSet();
     if(widget.servers){
       for(final id in channels.keys.toList()){if(!ids.contains(id))removeServer(id);}
       for(final d in docs){if(channels.containsKey(d.id))continue;
         late StreamSubscription<QuerySnapshot<Map<String,dynamic>>> sub;
         sub=d.reference.collection('channels').meowSnapshots().listen((cs){if(!mounted||generation!=epoch||!identical(channels[d.id],sub))return;final keys=cs.docs.map((x)=>'server:${d.id}:${x.id}').toSet();for(final key in threads.keys.where((k)=>k.startsWith('server:${d.id}:')&&!keys.contains(k)).toList()){drop(key);}for(final x in cs.docs){watchThread('server:${d.id}:${x.id}',x.reference.collection('messages'));}refresh();},onError:(Object _){if(mounted&&generation==epoch&&identical(channels[d.id],sub)){for(final key in threads.keys.where((k)=>k.startsWith('server:${d.id}:')).toList()){drop(key);}refresh();}});
         channels[d.id]=sub;
       }
     }else{for(final key in threads.keys.toList()){if(!ids.contains(key.substring(3)))drop(key);}for(final d in docs){watchThread('dm:${d.id}',d.reference.collection('messages'));}}
     refresh();
   },onError:(Object _){if(mounted&&generation==epoch){for(final id in channels.keys.toList()){removeServer(id);}for(final key in threads.keys.toList()){drop(key);}refresh();}});
 }
 void suspend(){epoch++;root?.cancel();root=null;for(final sub in channels.values){sub.cancel();}channels.clear();for(final t in threads.values){t.close();}threads.clear();unread=false;}
 @override void didChangeDependencies(){super.didChangeDependencies();if(TickerMode.of(context)){resume();}else{suspend();}}
 @override void didUpdateWidget(covariant MeowSectionUnread old){super.didUpdateWidget(old);if(old.uid!=widget.uid||old.servers!=widget.servers){suspend();if(TickerMode.of(context))resume();}}
 @override void dispose(){suspend();super.dispose();}
 @override Widget build(BuildContext c)=>MeowUnreadMark(unread:unread);
}
class MeowBottomBar extends StatelessWidget {
 final int index;final ValueChanged<int> onSelected;
 const MeowBottomBar({super.key,required this.index,required this.onSelected});
 Widget item(int i,IconData icon,String text){final color=index==i?purple:Colors.white54;return Expanded(child:InkWell(onTap:()=>onSelected(i),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Stack(clipBehavior:Clip.none,children:[Icon(icon,color:color,size:24),if(i==2||i==3)Positioned(right:-6,top:-4,child:MeowSectionUnread(uid:myUid,servers:i==2))]),const SizedBox(height:4),Text(text,style:TextStyle(fontSize:11,color:color),maxLines:1,overflow:TextOverflow.ellipsis)])));}
 @override Widget build(BuildContext c)=>Material(color:panel,child:SafeArea(top:false,child:SizedBox(height:66,child:Row(children:[item(0,Icons.home,'Home'),item(1,Icons.search,'Discover'),const Expanded(child:Center(child:ExcludeSemantics(child:CircleAvatar(radius:23,backgroundColor:purple,child:Icon(Icons.add,color:Colors.white,size:28))))),item(2,Icons.groups,'Servidores'),item(3,Icons.chat_bubble_outline,'Chat')]))));
}
class MeowDiscover extends StatefulWidget {
 final String uid;const MeowDiscover({super.key,required this.uid});
 @override State<MeowDiscover> createState()=>_MeowDiscoverState();
}
class _MeowDiscoverState extends State<MeowDiscover>{
 final search=TextEditingController();bool busy=false,more=false,searched=false;String? error;String query='';int generation=0;
 DocumentSnapshot<Map<String,dynamic>>? cursor;final results=<QueryDocumentSnapshot<Map<String,dynamic>>>[];
 @override void dispose(){generation++;search.dispose();super.dispose();}
 Future<void> find({bool next=false})async{
  if(next&&busy)return;
  final q=next?query:search.text.trim();final g=++generation;
  if(!next)setState((){query=q;results.clear();cursor=null;searched=q.isNotEmpty;more=false;});
  if(q.isEmpty){setState(()=>busy=false);return;}
  setState((){busy=true;error=null;});
  try{
   if(RegExp(r'^#?[0-9]{1,8}$').hasMatch(q)){final found=await meowFindUsers(q);if(mounted&&g==generation)setState(()=>results.addAll(found));return;}
   final lower=q.toLowerCase();var last=cursor;final found=<QueryDocumentSnapshot<Map<String,dynamic>>>[];var hasMore=true;
   // Scan at most 100 public profiles per action; use pagination rather than a forbidden unbounded query.
   for(var page=0;page<5;page++){
    Query<Map<String,dynamic>> req=db.collection('users').orderBy(FieldPath.documentId).limit(20);
    if(last!=null)req=req.startAfterDocument(last);
    final batch=await req.get();if(!mounted||g!=generation)return;
    found.addAll(batch.docs.where((d)=>(d.data()['displayName']?.toString()??'').toLowerCase().contains(lower)));
    if(batch.docs.isNotEmpty)last=batch.docs.last;
    if(batch.docs.length<20){hasMore=false;break;}
    if(found.length>=20)break;
   }
   if(mounted&&g==generation)setState((){cursor=last;more=hasMore;results.addAll(found);});
  }catch(_){if(mounted&&g==generation)setState(()=>error='Não foi possível pesquisar. Tente novamente.');}
  finally{if(mounted&&g==generation)setState(()=>busy=false);}
 }
 @override Widget build(BuildContext c)=>Column(children:[Padding(padding:const EdgeInsets.all(12),child:TextField(controller:search,textInputAction:TextInputAction.search,onSubmitted:(_)=>find(),decoration:InputDecoration(hintText:'Nome de exibição ou ID',prefixIcon:const Icon(Icons.search),suffixIcon:IconButton(tooltip:'Pesquisar',icon:const Icon(Icons.arrow_forward),onPressed:()=>find())))),
  Expanded(child:!searched?const Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(Icons.people_outline,size:46,color:purple),SizedBox(height:12),Text('Encontre seus amigos')])):ListView(children:[for(final d in results)ListTile(leading:ProfileAvatar(uid:d.id),title:Text(userLabel(d.data())),onTap:()=>openProfile(c,d.id)),if(busy)const Center(child:Padding(padding:EdgeInsets.all(16),child:CircularProgressIndicator())),if(error!=null)ListTile(title:Text(error!),trailing:TextButton(onPressed:()=>find(next:results.isNotEmpty),child:const Text('Tentar'))),if(!busy&&error==null&&results.isEmpty&&!more)const Center(child:Padding(padding:EdgeInsets.all(20),child:Text('Nenhum usuário encontrado.'))),if(more&&!busy)TextButton(onPressed:()=>find(next:true),child:const Text('Buscar mais resultados'))])),
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
 void sync(){final visible=TickerMode.of(context);final ids=visible?widget.ids.toSet():<String>{};for(final id in subs.keys.toList()){if(!ids.contains(id)){subs.remove(id)?.cancel();users.remove(id);}}for(final id in ids){subs.putIfAbsent(id,()=>db.collection('users').doc(id).meowSnapshots().listen((d){if(mounted&&subs.containsKey(id))setState(()=>users[id]=d.data()??{});},onError:(Object _){}));}timer?.cancel();timer=visible?Timer.periodic(const Duration(seconds:5),(_){if(mounted)setState((){});}):null;}
 @override void didChangeDependencies(){super.didChangeDependencies();sync();}
 @override void didUpdateWidget(covariant MeowOnlineCount old){super.didUpdateWidget(old);if(old.ids.length!=widget.ids.length||!old.ids.toSet().containsAll(widget.ids))sync();}
 @override void dispose(){timer?.cancel();for(final s in subs.values){s.cancel();}super.dispose();}
 @override Widget build(BuildContext c){final n=users.values.where((d)=>currentPresence(d)!='offline').length;return Row(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.circle,size:9,color:Colors.green),const SizedBox(width:6),Text('$n online',style:const TextStyle(fontSize:12,color:Colors.white54))]);}
}


// Meow 0.9.1: message search restricted to the exact conversation path.
// Firestore does not support arbitrary full text queries. Scan bounded cursor pages
// until a dedicated permission-checked search index is available.
class MeowChannelHistoryPage extends StatelessWidget {
 final String server,channel,name,uid;final String? initialMessageId;
 const MeowChannelHistoryPage({super.key,required this.server,required this.channel,required this.name,required this.uid,this.initialMessageId});
 @override Widget build(BuildContext c){
  final collection=db.collection('servers').doc(server).collection('channels').doc(channel).collection('messages');
  return Scaffold(appBar:AppBar(title:InkWell(onTap:()=>showMeowMembers(c,server),child:MeowChannelTitle(server:server,name:name)),actions:[MuteButton(thread:'server:$server:$channel'),MeowSearchButton(collection:collection,openResult:(c,message)=>Navigator.pushReplacement(c,MaterialPageRoute(builder:(_)=>MeowChannelHistoryPage(server:server,channel:channel,name:name,uid:uid,initialMessageId:message))))]),body:Stack(children:[MessageThread(collection:collection,uid:uid,serverId:server,threadId:'server:$server:$channel',initialMessageId:initialMessageId),Positioned(right:0,top:0,bottom:0,width:22,child:MeowEdgeSwipe(onOpen:()=>showMeowMembers(c,server)))]));
 }
}
class MeowSearchButton extends StatelessWidget {
 final CollectionReference<Map<String,dynamic>> collection;
 final void Function(BuildContext,String) openResult;
 const MeowSearchButton({super.key,required this.collection,required this.openResult});
 @override Widget build(BuildContext c)=>IconButton(tooltip:'Pesquisar mensagens',icon:const Icon(Icons.search),onPressed:()=>Navigator.push(c,MaterialPageRoute<void>(builder:(_)=>MeowMessageSearchPage(collection:collection,openResult:openResult))));
}
class MeowMessageSearchPage extends StatefulWidget {
 final CollectionReference<Map<String,dynamic>> collection;final void Function(BuildContext,String) openResult;
 const MeowMessageSearchPage({super.key,required this.collection,required this.openResult});
 @override State<MeowMessageSearchPage> createState()=>_MeowMessageSearchPageState();
}
class _MeowMessageSearchPageState extends State<MeowMessageSearchPage>{
 final query=TextEditingController();
 String kind='all',dateMode='';DateTime? date;DateTimeRange? range;
 String? authorId,authorName,mentionedId,mentionedName,mentionedSerial;
 late CollectionReference<Map<String,dynamic>> scope=widget.collection;
 String? channelName,savedChannelName;
 final results=<QueryDocumentSnapshot<Map<String,dynamic>>>[];
 QueryDocumentSnapshot<Map<String,dynamic>>? cursor;
 bool busy=false,started=false,more=true;int scanned=0;String? error;
 String savedQuery='',savedKind='all',savedDateMode='';String? savedAuthor,savedMention,savedMentionSerial,savedMentionName;DateTime? savedDate;DateTimeRange? savedRange;
 late CollectionReference<Map<String,dynamic>> savedScope=widget.collection;
 bool get server=>widget.collection.path.startsWith('servers/');
 String get serverId=>widget.collection.path.split('/')[1];
 @override void dispose(){query.dispose();super.dispose();}
 bool matches(Map<String,dynamic> d){
  final text=d['text']?.toString()??'';if(savedQuery.isNotEmpty&&!text.toLowerCase().contains(savedQuery))return false;
  if(savedAuthor!=null&&d['authorId']!=savedAuthor)return false;
  if(savedMention!=null){final names=mentionNames(text);final serial=savedMentionSerial??'';if((serial.isEmpty||!names.contains('#$serial'))&&!names.contains((savedMentionName??'').toLowerCase()))return false;}
  final attachments=meowAttachments(d);final expression=d['expression'];
  bool mime(String prefix)=>attachments.any((a)=>(a['contentType']?.toString()??'').toLowerCase().startsWith(prefix));
  return switch(savedKind){'image'=>attachments.any((a){final type=(a['contentType']?.toString()??'').toLowerCase();return type.startsWith('image/')&&type!='image/gif';}),'video'=>mime('video/'),'gif'=>mime('image/gif'),'link'=>RegExp(r'https?://',caseSensitive:false).hasMatch(text)||meowInviteCode(text,linkOnly:true)!=null,'file'=>attachments.isNotEmpty,'sticker'=>expression is Map&&expression['kind']=='sticker','emoji'=>expression is Map&&expression['kind']=='emoji',_=>true};
 }
 Future<void> choosePerson(bool mention)async{
  try{final parent=server?db.collection('servers').doc(serverId):widget.collection.parent!;final d=(await parent.get()).data()??{};final ids=List<String>.from(d['members']??[]);final people=<Map<String,dynamic>>[];
   for(final uid in ids){final p=await db.collection('users').doc(uid).get();if(p.exists){final data=p.data()??{};people.add({'uid':uid,'name':userLabel(data),'serial':meowSerial(data)});}}
   if(!mounted)return;final selected=await showMeowFilterPicker(context,mention?'Mencionar alguém':'De uma pessoa específica',people.map((p)=>MeowFilterOption(p['uid'].toString(),p['name'].toString(),p['serial'].toString())).toList(),people:true);
   if(selected==null||!mounted)return;setState((){if(mention){mentionedId=selected.id;mentionedName=selected.name;mentionedSerial=selected.detail;}else{authorId=selected.id;authorName=selected.name;}});
  }catch(e){if(mounted)notice(context,'Não foi possível carregar os membros.');}
 }
 Future<void> chooseChannel()async{if(!server)return;try{final docs=await db.collection('servers').doc(serverId).collection('channels').get();if(!mounted)return;final picked=await showMeowFilterPicker(context,'Em um canal específico',docs.docs.map((d)=>MeowFilterOption(d.id,d.data()['name']?.toString()??'canal','')).toList());if(picked!=null&&mounted)setState((){scope=db.collection('servers').doc(serverId).collection('channels').doc(picked.id).collection('messages');channelName=picked.name;});}catch(e){if(mounted)notice(context,'Não foi possível carregar os canais.');}}
 Future<void> chooseDate(String mode)async{final now=DateTime.now();if(mode=='range'){final value=await showDateRangePicker(context:context,firstDate:DateTime(2020),lastDate:now,initialDateRange:range);if(value!=null&&mounted)setState((){range=value;date=null;dateMode='range';});return;}
  DateTime value=date??now;final selected=await showModalBottomSheet<DateTime>(context:context,showDragHandle:true,builder:(c)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[const Text('Escolha uma data',style:TextStyle(fontWeight:FontWeight.bold,fontSize:19)),SizedBox(height:180,child:CupertinoDatePicker(mode:CupertinoDatePickerMode.date,initialDateTime:value,minimumDate:DateTime(2020),maximumDate:now,onDateTimeChanged:(v)=>value=v)),Row(mainAxisAlignment:MainAxisAlignment.end,children:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Cancelar')),FilledButton(onPressed:()=>Navigator.pop(c,value),child:const Text('Confirmar')),const SizedBox(width:12)]),const SizedBox(height:12)])));
  if(selected!=null&&mounted)setState((){date=selected;range=null;dateMode=mode;});
 }
 Future<void> chooseKind()async{final options={'all':'Todos','image':'Imagens','video':'Vídeos','gif':'GIFs','file':'Arquivos','link':'Links','sticker':'Figurinhas','emoji':'Emojis personalizados'};final value=await showModalBottomSheet<String>(context:context,showDragHandle:true,builder:(c)=>SafeArea(child:ListView(shrinkWrap:true,children:[const ListTile(title:Text('Possui dados específicos')),for(final e in options.entries)ListTile(title:Text(e.value),trailing:e.key==kind?const Icon(Icons.check,color:purple):null,onTap:()=>Navigator.pop(c,e.key))])));if(value!=null&&mounted)setState(()=>kind=value);}
 Future<void> filter(String v)async{switch(v){case 'author':await choosePerson(false);break;case 'channel':await chooseChannel();break;case 'kind':await chooseKind();break;case 'mention':await choosePerson(true);break;default:await chooseDate(v);}}
 Future<void> search({bool next=false})async{
  if(busy)return;if(!next&&query.text.trim().isEmpty&&authorId==null&&mentionedId==null&&kind=='all'&&dateMode.isEmpty&&channelName==null){notice(context,'Informe um termo ou filtro.');return;}
  FocusManager.instance.primaryFocus?.unfocus();setState((){busy=true;error=null;if(!next){started=true;results.clear();cursor=null;more=true;scanned=0;savedQuery=query.text.trim().toLowerCase();savedAuthor=authorId;savedMention=mentionedId;savedMentionSerial=mentionedSerial;savedMentionName=mentionedName;savedKind=kind;savedDateMode=dateMode;savedDate=date;savedRange=range;savedScope=scope;savedChannelName=channelName;}});
  try{Query<Map<String,dynamic>> base=savedScope.orderBy('createdAt',descending:true);DateTime? start,end;DateTime floor(DateTime d)=>DateTime(d.year,d.month,d.day);DateTime nextDay(DateTime d)=>DateTime(d.year,d.month,d.day+1);
   final dt=savedDate;if(dt!=null){if(savedDateMode=='on'){start=floor(dt);end=nextDay(dt);}if(savedDateMode=='before')end=floor(dt);if(savedDateMode=='after')start=nextDay(dt);}
   final r=savedRange;if(savedDateMode=='range'&&r!=null){start=floor(r.start);end=nextDay(r.end);}
   if(start!=null)base=base.where('createdAt',isGreaterThanOrEqualTo:Timestamp.fromDate(start));if(end!=null)base=base.where('createdAt',isLessThan:Timestamp.fromDate(end));
   final beforeCount=results.length;
   for(var page=0;page<3&&more;page++){final snap=await (cursor==null?base:base.startAfterDocument(cursor!)).limit(50).get(const GetOptions(source:Source.server)).timeout(const Duration(seconds:20));if(!mounted)return;setState((){scanned+=snap.docs.length;if(snap.docs.isNotEmpty)cursor=snap.docs.last;more=snap.docs.length==50;results.addAll(snap.docs.where((d)=>matches(d.data())));});if(results.length-beforeCount>=50)break;}
  }catch(e){if(mounted)setState(()=>error='Não foi possível pesquisar. Verifique a conexão e o acesso à conversa.');}finally{if(mounted)setState(()=>busy=false);}
 }
 void open(QueryDocumentSnapshot<Map<String,dynamic>> doc){if(savedScope.path==widget.collection.path){widget.openResult(context,doc.id);return;}final p=doc.reference.path.split('/');if(p.length==6&&p.first=='servers'){Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>MeowChannelHistoryPage(server:p[1],channel:p[3],name:savedChannelName??'canal',uid:myUid,initialMessageId:doc.id)));}}
 String dateLabel(DateTime d)=>'${d.day}/${d.month}/${d.year}';
 Widget chip(String label,VoidCallback clear)=>InputChip(label:Text(label),onDeleted:busy?null:clear);
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Pesquisar mensagens'),actions:[PopupMenuButton<String>(tooltip:'Filtrar resultados',enabled:!busy,icon:const Icon(Icons.tune),onSelected:filter,itemBuilder:(_)=>[const PopupMenuItem(enabled:false,child:Text('Filtrar resultados…')),const PopupMenuItem(value:'author',child:ListTile(leading:Icon(Icons.person_outline),title:Text('De uma pessoa específica'))),if(server)const PopupMenuItem(value:'channel',child:ListTile(leading:Icon(Icons.tag),title:Text('Em um canal específico'))),const PopupMenuItem(value:'kind',child:ListTile(leading:Icon(Icons.attach_file),title:Text('Possui dados específicos'))),const PopupMenuItem(value:'mention',child:ListTile(leading:Icon(Icons.alternate_email),title:Text('Mencionar alguém'))),const PopupMenuItem(value:'on',child:ListTile(leading:Icon(Icons.event),title:Text('Enviado em uma data'))),const PopupMenuItem(value:'before',child:ListTile(leading:Icon(Icons.event_busy),title:Text('Antes de uma data'))),const PopupMenuItem(value:'after',child:ListTile(leading:Icon(Icons.event_available),title:Text('Após uma data'))),const PopupMenuItem(value:'range',child:ListTile(leading:Icon(Icons.date_range),title:Text('Intervalo de datas')))])]),body:Column(children:[Padding(padding:const EdgeInsets.fromLTRB(12,8,12,4),child:TextField(controller:query,enabled:!busy,textInputAction:TextInputAction.search,onSubmitted:(_)=>search(),decoration:InputDecoration(hintText:'Pesquisar mensagens',prefixIcon:const Icon(Icons.search),suffixIcon:IconButton(onPressed:busy?null:()=>search(),icon:const Icon(Icons.arrow_forward))))),Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Wrap(spacing:6,children:[if(authorId!=null)chip('de: $authorName',()=>setState((){authorId=null;authorName=null;})),if(channelName!=null)chip('em: #$channelName',()=>setState((){channelName=null;scope=widget.collection;})),if(mentionedId!=null)chip('menções: $mentionedName',()=>setState((){mentionedId=null;mentionedName=null;mentionedSerial=null;})),if(kind!='all')chip('tem: $kind',()=>setState(()=>kind='all')),if(date!=null)chip('${dateMode=='on'?'em':dateMode=='before'?'antes':'depois'}: ${dateLabel(date!)}',()=>setState((){date=null;dateMode='';})),if(range!=null)chip('${dateLabel(range!.start)} – ${dateLabel(range!.end)}',()=>setState((){range=null;dateMode='';}))])),if(busy)const LinearProgressIndicator(),if(started)Padding(padding:const EdgeInsets.all(8),child:Text('${results.length} resultado(s) • $scanned mensagens consultadas',style:const TextStyle(color:Colors.white70,fontSize:12))),Expanded(child:!started?const Center(child:Text('Pesquise no histórico ou selecione filtros.')):ListView.builder(itemCount:results.length+1,itemBuilder:(c,i){if(i==results.length)return Padding(padding:const EdgeInsets.all(16),child:Column(children:[if(error!=null)Text(error!),if(!busy&&more)OutlinedButton(onPressed:()=>search(next:true),child:Text(error==null?'Buscar mais mensagens antigas':'Tentar novamente')),if(!busy&&!more)Text(results.isEmpty?'Nenhuma mensagem encontrada.':'Fim do histórico pesquisado.')]));final doc=results[i],d=doc.data();final t=d['createdAt'];final who=d['authorId']?.toString()??'';return ListTile(leading:who.isEmpty||who=='system'?const Icon(Icons.info_outline):ProfileAvatar(uid:who,size:44,showPresence:false),title:Text(d['author']?.toString()??'Usuário'),subtitle:Text((d['text']?.toString()??'').isEmpty?'Mídia ou anexo':d['text'].toString(),maxLines:2,overflow:TextOverflow.ellipsis),trailing:Text(t is Timestamp?formatMeowTime(t.toDate()):'',style:const TextStyle(fontSize:11)),onTap:()=>open(doc));}))]));
}
class MeowFilterOption{final String id,name,detail;const MeowFilterOption(this.id,this.name,this.detail);}
Future<MeowFilterOption?> showMeowFilterPicker(BuildContext context,String title,List<MeowFilterOption> values,{bool people=false})async{
 String filter='';return showModalBottomSheet<MeowFilterOption>(context:context,isScrollControlled:true,showDragHandle:true,builder:(c)=>SafeArea(child:Padding(padding:EdgeInsets.only(bottom:MediaQuery.viewInsetsOf(c).bottom),child:SizedBox(height:max(180.0,min(440.0,MediaQuery.sizeOf(c).height-MediaQuery.viewInsetsOf(c).bottom-80)),child:StatefulBuilder(builder:(c,setLocal){final items=values.where((v)=>v.name.toLowerCase().contains(filter.toLowerCase())||v.detail.contains(filter)).toList();return Column(children:[Padding(padding:const EdgeInsets.all(12),child:TextField(autofocus:true,onChanged:(v)=>setLocal(()=>filter=v),decoration:InputDecoration(hintText:title,prefixIcon:const Icon(Icons.search)))),Expanded(child:ListView.builder(itemCount:items.length,itemBuilder:(c,i){final v=items[i];return ListTile(leading:people?ProfileAvatar(uid:v.id,size:44):const Icon(Icons.tag),title:Text(v.name),subtitle:people&&v.detail.isNotEmpty?Text('#${v.detail}'):null,onTap:()=>Navigator.pop(c,v));}))]);})))));
}

// Invite links are opaque bearer tokens. No private server lookup by the client
// before accepting an invitation. The trusted endpoint validates all joins.
const meowInviteBase=String.fromEnvironment('MEOW_INVITE_BASE',defaultValue:'meow://invite/');
String meowInviteLink(String code)=>'$meowInviteBase$code';
String? meowInviteCode(String raw,{bool linkOnly=false}){
 final value=raw.trim();String token=value;
 if(value.startsWith(meowInviteBase)){token=value.substring(meowInviteBase.length);}
 else if(value.startsWith('meow://invite/')){token=value.substring('meow://invite/'.length);}
 else if(linkOnly)return null;
 if(RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(token))return token.toLowerCase();
 if(RegExp(r'^[A-HJ-NP-Z2-9]{10}$',caseSensitive:false).hasMatch(token))return token.toUpperCase();return null;
}
Future<Map<String,dynamic>> meowInviteAction(Map<String,dynamic> body)async{
 final uid=myUid;final response=await http.post(Uri.https(imageHost,'/functions/v1/meow-convites'),headers:{...await authHeaders(),'Content-Type':'application/json'},body:jsonEncode(body)).timeout(const Duration(seconds:45));
 if(FirebaseAuth.instance.currentUser?.uid!=uid)throw Exception('Sessão alterada.');
 final decoded=jsonDecode(response.body);if(decoded is! Map)throw Exception('Serviço de convites indisponível.');
 if(response.statusCode!=200||decoded['ok']!=true)throw Exception(decoded['error']?.toString()??'Não foi possível concluir o convite.');return Map<String,dynamic>.from(decoded);
}
Future<void> sendMeowInvite(String other,String code)async{
 final uid=myUid;final room=db.collection('dms').doc(dmId(uid,other));
 final a=db.collection('users').doc(uid).collection('following').doc(other),b=db.collection('users').doc(other).collection('following').doc(uid);
 // Only mutual friends can receive an invite through this shortcut.
 await db.runTransaction((tx)async{final ra=await tx.get(a),rb=await tx.get(b),existing=await tx.get(room);if(!ra.exists||!rb.exists)throw Exception('Este usuário não é mais seu amigo.');if(!existing.exists)tx.set(room,{'members':[uid,other]..sort()});});
 final profile=(await db.collection('users').doc(uid).get()).data()??{};final message=room.collection('messages').doc();
 await db.runTransaction((tx)async{final ra=await tx.get(a),rb=await tx.get(b);if(!ra.exists||!rb.exists)throw Exception('Este usuário não é mais seu amigo.');tx.set(message,{'text':meowInviteLink(code),'authorId':uid,'author':userLabel(profile),'createdAt':FieldValue.serverTimestamp()});});
 unawaited(notifyMessage(message.path));
}
class MeowInvitesPage extends StatefulWidget{
 final String server,name;const MeowInvitesPage({super.key,required this.server,required this.name});
 @override State<MeowInvitesPage> createState()=>_MeowInvitesPageState();
}
class _MeowInvitesPageState extends State<MeowInvitesPage>{
 final search=TextEditingController();late Future<List<Map<String,dynamic>>> friends;late Future<List<dynamic>> invites;
 String? code;int days=7,maxUses=0;bool busy=false;final sent=<String>{},sending=<String>{};
 @override void initState(){super.initState();friends=loadFriends();invites=loadInvites();}
 @override void dispose(){search.dispose();super.dispose();}
 Future<List<Map<String,dynamic>>> loadFriends()async{final uid=myUid;final list=await db.collection('users').doc(uid).collection('following').get();final result=<Map<String,dynamic>>[];for(final f in list.docs){final mutual=await db.collection('users').doc(f.id).collection('following').doc(uid).get();if(!mutual.exists)continue;final p=await db.collection('users').doc(f.id).get();if(p.exists)result.add({'uid':f.id,'name':userLabel(p.data()??{})});}result.sort((a,b)=>a['name'].toString().compareTo(b['name'].toString()));return result;}
 Future<List<dynamic>> loadInvites()async{final response=await meowInviteAction({'action':'list','serverId':widget.server});return List<dynamic>.from(response['invites'] as List? ?? []);}
 Future<void> create()async{if(busy)return;setState(()=>busy=true);try{final d=await meowInviteAction({'action':'create','serverId':widget.server,'days':days,'maxUses':maxUses});if(mounted)setState((){code=d['code'].toString();sent.clear();invites=loadInvites();});}catch(e){if(mounted)notice(context,e);}finally{if(mounted)setState(()=>busy=false);}}
 Future<void> revoke(String token)async{try{await meowInviteAction({'action':'revoke','serverId':widget.server,'code':token});if(mounted)setState((){if(code==token)code=null;invites=loadInvites();});}catch(e){if(mounted)notice(context,e);}}
 Future<void> invite(String uid)async{final token=code;if(token==null||sending.contains(uid))return;setState(()=>sending.add(uid));try{await sendMeowInvite(uid,token);if(mounted&&code==token)setState(()=>sent.add(uid));}catch(e){if(mounted)notice(context,e);}finally{if(mounted)setState(()=>sending.remove(uid));}}
 @override Widget build(BuildContext c)=>ListView(padding:const EdgeInsets.all(16),children:[Text('Convidar um amigo',textAlign:TextAlign.center,style:Theme.of(c).textTheme.titleLarge),const SizedBox(height:16),Row(children:[Expanded(child:DropdownButtonFormField<int>(value:days,decoration:const InputDecoration(labelText:'Validade'),items:const [DropdownMenuItem(value:1,child:Text('1 dia')),DropdownMenuItem(value:7,child:Text('7 dias')),DropdownMenuItem(value:30,child:Text('30 dias')),DropdownMenuItem(value:0,child:Text('Nunca'))],onChanged:busy?null:(v){if(v!=null)setState(()=>days=v);})),const SizedBox(width:8),Expanded(child:DropdownButtonFormField<int>(value:maxUses,decoration:const InputDecoration(labelText:'Utilizações'),items:const [DropdownMenuItem(value:0,child:Text('Ilimitadas')),DropdownMenuItem(value:1,child:Text('1')),DropdownMenuItem(value:5,child:Text('5')),DropdownMenuItem(value:10,child:Text('10')),DropdownMenuItem(value:25,child:Text('25'))],onChanged:busy?null:(v){if(v!=null)setState(()=>maxUses=v);}))]),const SizedBox(height:12),FilledButton.icon(onPressed:busy?null:create,icon:const Icon(Icons.link),label:Text(busy?'Criando…':'Gerar link de convite')),if(code!=null)...[SelectableText(meowInviteLink(code!)),Wrap(alignment:WrapAlignment.spaceEvenly,children:[TextButton.icon(onPressed:()async{await Clipboard.setData(ClipboardData(text:meowInviteLink(code!)));if(mounted)notice(context,'Link copiado.');},icon:const Icon(Icons.copy),label:const Text('Copiar link')),TextButton.icon(onPressed:()=>Share.share(meowInviteLink(code!)),icon:const Icon(Icons.share),label:const Text('Compartilhar'))])],const Divider(),TextField(controller:search,onChanged:(_)=>setState((){}),decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'Convidar amigos para ${widget.name}')),FutureBuilder<List<Map<String,dynamic>>>(future:friends,builder:(c,s){if(s.hasError)return const Text('Não foi possível carregar os amigos.');if(!s.hasData)return const Center(child:CircularProgressIndicator());final list=s.data!.where((u)=>u['name'].toString().toLowerCase().contains(search.text.toLowerCase()));return Column(children:[for(final f in list)ListTile(leading:ProfileAvatar(uid:f['uid'].toString(),size:44),title:Text(f['name'].toString()),trailing:FilledButton.tonal(onPressed:code==null||sent.contains(f['uid'])||sending.contains(f['uid'])?null:()=>invite(f['uid'].toString()),child:Text(sent.contains(f['uid'])?'Enviado':sending.contains(f['uid'])?'Enviando…':'Convidar'))),if(list.isEmpty)const Text('Nenhum amigo encontrado.')]);}),const Divider(),const Text('Links existentes',style:TextStyle(fontWeight:FontWeight.bold)),FutureBuilder<List<dynamic>>(future:invites,builder:(c,s){if(s.hasError)return TextButton(onPressed:()=>setState(()=>invites=loadInvites()),child:const Text('Tentar carregar convites'));if(!s.hasData)return const Center(child:CircularProgressIndicator());return Column(children:[for(final d in s.data!)if(d is Map)ListTile(title:Text(d['active']==true?'Convite ativo':'Inativo'),subtitle:Text('${d['uses']??0} utilizações'),onTap:d['active']==true?()=>setState(()=>code=d['code'].toString()):null,trailing:d['active']==true?IconButton(tooltip:'Revogar convite',onPressed:()=>revoke(d['code'].toString()),icon:const Icon(Icons.delete_outline)):null)]);})]);
}
class MeowInviteCard extends StatefulWidget{
 final String code;const MeowInviteCard({super.key,required this.code});@override State<MeowInviteCard> createState()=>_MeowInviteCardState();
}
class _MeowInviteCardState extends State<MeowInviteCard>{
 late Future<Map<String,dynamic>> info;bool busy=false,joined=false;
 @override void initState(){super.initState();info=meowInviteAction({'action':'inspect','code':widget.code});}
 Future<void> accept()async{if(busy||joined)return;setState(()=>busy=true);try{final d=await meowInviteAction({'action':'join','code':widget.code});if(mounted){setState(()=>joined=true);notice(context,d['alreadyMember']==true?'Você já está no servidor.':'Você entrou no servidor!');}}catch(e){if(mounted)notice(context,e);}finally{if(mounted)setState(()=>busy=false);}}
 @override Widget build(BuildContext c)=>Card(color:panel,child:Padding(padding:const EdgeInsets.all(12),child:FutureBuilder<Map<String,dynamic>>(future:info,builder:(c,s){if(s.hasError)return Column(children:[const Text('Convite indisponível ou expirado.'),TextButton(onPressed:()=>setState(()=>info=meowInviteAction({'action':'inspect','code':widget.code})),child:const Text('Tentar novamente'))]);if(!s.hasData)return const Padding(padding:EdgeInsets.all(12),child:CircularProgressIndicator());final d=s.data!;return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[const Text('CONVITE PARA UM SERVIDOR',style:TextStyle(fontSize:11,color:Colors.white70)),const SizedBox(height:8),Row(children:[const Icon(Icons.groups,size:36),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(d['name']?.toString()??'Servidor',style:const TextStyle(fontSize:17,fontWeight:FontWeight.bold)),Text('${d['memberCount']??0} membros',style:const TextStyle(color:Colors.white70))]))]),const SizedBox(height:10),FilledButton(onPressed:busy||joined||d['joined']==true?null:accept,child:Text(joined||d['joined']==true?'Já é membro':busy?'Entrando…':'Entrar no servidor'))]);})));
}
class MeowWelcomeSettings extends StatefulWidget{
 final String server;const MeowWelcomeSettings({super.key,required this.server});@override State<MeowWelcomeSettings> createState()=>_MeowWelcomeSettingsState();
}
class _MeowWelcomeSettingsState extends State<MeowWelcomeSettings>{
 bool busy=false;Future<void> save(bool enabled,String channel)async{if(busy)return;setState(()=>busy=true);try{await meowInviteAction({'action':'welcome','serverId':widget.server,'enabled':enabled,'channel':channel});}catch(e){if(mounted)notice(context,e);}finally{if(mounted)setState(()=>busy=false);}}
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Boas-vindas')),body:MeowStreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('servers').doc(widget.server).meowSnapshots(),builder:(c,s){if(!s.hasData)return const Center(child:CircularProgressIndicator());final d=s.data!.data()??{};final enabled=d['welcomeEnabled']!=false;final selected=d['welcomeChannelId']?.toString()??'';return MeowStreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('servers').doc(widget.server).collection('channels').meowSnapshots(),builder:(c,ch){final docs=ch.data?.docs??[];return ListView(padding:const EdgeInsets.all(12),children:[SwitchListTile(title:const Text('Mensagens de boas-vindas'),value:enabled,onChanged:busy?null:(v)=>save(v,selected)),ListTile(title:const Text('Canal de boas-vindas'),subtitle:const Text('O canal geral é usado por padrão.')),DropdownButtonFormField<String>(value:docs.any((x)=>x.id==selected)?selected:'',items:[const DropdownMenuItem(value:'',child:Text('Canal principal')),for(final x in docs)DropdownMenuItem(value:x.id,child:Text('# ${x.data()['name']??'canal'}'))],onChanged:busy?null:(v){if(v!=null)save(enabled,v);})]);});}));
}

// Permission is requested only on opening the gallery explicitly. The OS
// picker remains available without granting the app broad photo access.
class MeowAttachmentPicker extends StatefulWidget {
 final int maxCount;const MeowAttachmentPicker({super.key,required this.maxCount});
 @override State<MeowAttachmentPicker> createState()=>_MeowAttachmentPickerState();
}
class _MeowAttachmentPickerState extends State<MeowAttachmentPicker>{
 final items=<gallery.AssetEntity>[];
 final selected=<String,gallery.AssetEntity>{};
 final thumbs=<String,Future<Uint8List?>>{};
 gallery.AssetPathEntity? album;
 bool busy=false,opened=false,more=true;String? error;int page=0;
 Future<void> openGallery()async{
  if(busy)return;setState((){busy=true;error=null;});
  try{final permission=await gallery.PhotoManager.requestPermissionExtend();if(!mounted)return;if(permission!=gallery.PermissionState.authorized&&permission!=gallery.PermissionState.limited){setState(()=>error='Sem acesso à galeria. Use o seletor do celular.');return;}
   final albums=await gallery.PhotoManager.getAssetPathList(onlyAll:true,type:gallery.RequestType.common);if(!mounted)return;
   setState((){opened=true;items.clear();selected.clear();thumbs.clear();page=0;album=albums.isEmpty?null:albums.first;more=album!=null;});if(album!=null)await fetchPage();
  }catch(_){if(mounted)setState(()=>error='Não foi possível abrir a galeria.');}finally{if(mounted)setState(()=>busy=false);}
 }
 Future<void> fetchPage()async{final path=album;if(path==null||!more)return;final result=await path.getAssetListPaged(page:page,size:60);if(!mounted)return;setState((){items.addAll(result.where((a)=>!items.any((b)=>b.id==a.id)));page++;more=result.length==60;});}
 Future<void> next()async{if(busy||!more)return;setState(()=>busy=true);try{await fetchPage();}catch(_){if(mounted)setState(()=>error='Falha ao carregar mais mídias.');}finally{if(mounted)setState(()=>busy=false);}}
 Future<void> native(bool documents)async{if(busy)return;setState(()=>busy=true);try{final result=documents?await files.openFiles():await ImagePicker().pickMultipleMedia(requestFullMetadata:false);if(mounted&&result.isNotEmpty)Navigator.pop(context,result.take(widget.maxCount).toList());}catch(_){if(mounted)setState(()=>error='Não foi possível abrir o seletor.');}finally{if(mounted)setState(()=>busy=false);}}
 Future<void> confirm()async{if(busy||selected.isEmpty)return;setState(()=>busy=true);try{final result=<files.XFile>[];for(final asset in selected.values){final f=await asset.originFile;if(f!=null)result.add(files.XFile(f.path));}if(!mounted)return;if(result.length!=selected.length){setState(()=>error='Alguma mídia não está disponível. Tente o seletor do celular.');return;}Navigator.pop(context,result);}catch(_){if(mounted)setState(()=>error='Não foi possível preparar os anexos.');}finally{if(mounted)setState(()=>busy=false);}}
 Future<Uint8List?> thumb(gallery.AssetEntity a){if(thumbs.length>=120&&!thumbs.containsKey(a.id))thumbs.remove(thumbs.keys.first);return thumbs.putIfAbsent(a.id,()=>a.thumbnailDataWithSize(const gallery.ThumbnailSize(160,160)));}
 @override Widget build(BuildContext c)=>SafeArea(child:SizedBox(height:MediaQuery.sizeOf(c).height*.68,child:Column(children:[Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Row(children:[const Expanded(child:Text('Adicionar anexos',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold))),Text('${selected.length}/${widget.maxCount}')])),if(busy)const LinearProgressIndicator(),if(error!=null)Padding(padding:const EdgeInsets.all(8),child:Text(error!,style:const TextStyle(color:Colors.orangeAccent))),Expanded(child:!opened?Center(child:FilledButton.icon(onPressed:busy?null:openGallery,icon:const Icon(Icons.photo_library_outlined),label:const Text('Mostrar galeria'))):items.isEmpty?const Center(child:Text('Nenhuma mídia disponível.')):GridView.builder(padding:const EdgeInsets.all(8),gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:4,crossAxisSpacing:4,mainAxisSpacing:4),itemCount:items.length+(more?1:0),itemBuilder:(c,i){if(i==items.length)return IconButton(onPressed:busy?null:next,icon:const Icon(Icons.expand_more),tooltip:'Carregar mais');final a=items[i];final checked=selected.containsKey(a.id);return InkWell(onTap:busy?null:(){setState((){if(checked){selected.remove(a.id);}else if(selected.length<widget.maxCount){selected[a.id]=a;}});},child:Stack(fit:StackFit.expand,children:[FutureBuilder<Uint8List?>(future:thumb(a),builder:(c,s)=>s.data==null?const ColoredBox(color:meowComposerColor,child:Icon(Icons.image_outlined)):Image.memory(s.data!,fit:BoxFit.cover,cacheWidth:160,gaplessPlayback:true)),if(a.type==gallery.AssetType.video)const Positioned(left:4,bottom:4,child:Icon(Icons.play_circle_fill,color:Colors.white,size:20)),if(checked)Container(decoration:BoxDecoration(border:Border.all(color:purple,width:3),color:Colors.black26)),Positioned(top:3,right:3,child:Icon(checked?Icons.check_circle:Icons.radio_button_unchecked,color:checked?purple:Colors.white,size:23))]));})),const Divider(height:1),Padding(padding:const EdgeInsets.all(8),child:Row(children:[Expanded(child:TextButton.icon(onPressed:busy?null:()=>native(false),icon:const Icon(Icons.photo_outlined),label:const Text('Galeria'))),Expanded(child:TextButton.icon(onPressed:busy?null:()=>native(true),icon:const Icon(Icons.attach_file),label:const Text('Arquivos'))),FilledButton(onPressed:busy||selected.isEmpty?null:confirm,child:const Text('Adicionar'))])),Text('Até ${fileSizeLabel(attachmentLimit)} por arquivo',style:const TextStyle(fontSize:12,color:Colors.white54)),const SizedBox(height:6)])));
}
