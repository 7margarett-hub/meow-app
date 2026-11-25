import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow/main.dart';

void main(){
 test('Unidades decimais e limites preservados',(){
  expect(fileSizeLabel(1000),'1.0 KB');
  expect(fileSizeLabel(1000000),'1.0 MB');
  expect(fileSizeLabel(1024000,preferMB:true),'1.0 MB');
  expect(fileSizeLabel(1000000000),'1.0 GB');
  expect(attachmentLimit,26214400);
  expect(fileSizeLabel(attachmentLimit),'26.2 MB');
 });
 test('Convites novos e legados, rejeita tokens e URLs inválidos',(){
  const code='0123456789abcdef0123456789abcdef';
  expect(meowInviteCode(meowInviteLink(code),linkOnly:true),code);
  expect(meowInviteCode('ABCDEFGHJK'),'ABCDEFGHJK');
  expect(meowInviteCode('https://example.com/$code'),isNull);
  expect(meowInviteCode(code,linkOnly:true),isNull);
  expect(meowInviteCode('meow://invite/$code?x=1'),isNull);
 });
 test('Menções e avatares',(){
  expect(mentionNames('oi @#00000001 @everyone'),{'#00000001','everyone'});
  expect(meowChatAvatarSize,44);
 });
 test('Prévia usa resolução proporcional, limitada e reutilizável',(){
  expect(meowPreviewPixels(44,2),128);
  expect(meowPreviewPixels(44,3),256);
  expect(meowPreviewPixels(400,3),1536);
  expect(meowPreviewPixels(double.infinity,2),0);
  expect(meowPreviewPixels(0,2),0);
  expect(meowStaticPreview(Uint8List.fromList([255,216,255,224,0,0,0,0])),isTrue);
  expect(meowStaticPreview(Uint8List.fromList([71,73,70,56,57,97,0,0])),isFalse);
 });
 testWidgets('Indicador não lido é circular e verde, desaparece quando lido',(tester)async{
  await tester.pumpWidget(const MaterialApp(home:Scaffold(body:Center(child:MeowUnreadMark(unread:true)))));
  final mark=find.descendant(of:find.byType(MeowUnreadMark),matching:find.byType(DecoratedBox));
  expect(mark,findsOneWidget);
  final decoration=tester.widget<DecoratedBox>(mark).decoration as BoxDecoration;
  expect(decoration.shape,BoxShape.circle);expect(decoration.color,const Color(0xFF39F57A));
  expect(tester.getSize(find.byType(MeowUnreadMark)),const Size(10,10));
  await tester.pumpWidget(const MaterialApp(home:Scaffold(body:Center(child:MeowUnreadMark(unread:false)))));
  expect(mark,findsNothing);
 });
 testWidgets('As três insígnias usam suas artes aprovadas',(tester)async{
  await tester.pumpWidget(MaterialApp(home:Scaffold(body:Row(children:[for(final b in meowBadgeDefinitions)meowBadgeArt(b)]))));
  final images=tester.widgetList<Image>(find.byType(Image)).map((i)=>(i.image as AssetImage).assetName).toList();
  expect(images,['assets/badges/developer.png','assets/badges/beta_tester.png','assets/badges/bug_hunter.png']);
  await tester.pumpAndSettle();
 });
 testWidgets('Markdown combinado e texto malformado', (tester)async{
  Future<void> show(String text)async{await tester.pumpWidget(MaterialApp(home:Scaffold(body:MeowMessageText(text:text,people:const {}))));await tester.pump();}
  await show('__***Meow***__');
  final match=find.byWidgetPredicate((w)=>w is Text&&w.textSpan?.toPlainText()=='Meow');
  expect(match,findsOneWidget);
  final span=(tester.widget<Text>(match).textSpan as TextSpan).children!.whereType<TextSpan>().firstWhere((s)=>s.text=='Meow');
  expect(span.style?.fontWeight,FontWeight.bold);expect(span.style?.fontStyle,FontStyle.italic);expect(span.style?.decoration,TextDecoration.underline);
  await show('*** aberto');
  expect(find.byWidgetPredicate((w)=>w is Text&&w.textSpan?.toPlainText()=='*** aberto'),findsOneWidget);
 });
}
