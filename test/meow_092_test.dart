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
  expect(meowChatAvatarSize,54);
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
