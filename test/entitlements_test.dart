import 'package:parchis_server/entitlements.dart';
import 'package:test/test.dart';

const _gold = CatalogItem('dice_gold', ItemType.dice, priceCents: 199);
const _jungle = CatalogItem('board_jungle', ItemType.board, priceCents: 299);

void main() {
  late EntitlementService service;

  setUp(() {
    service = EntitlementService(
      MemoryEntitlementStore(),
      catalog: [...defaultCatalog, _gold, _jungle],
    );
  });

  test('free items are owned by everyone, guests included', () async {
    expect(await service.owns('u1', defaultDiceSkin), isTrue);
    expect(await service.owns(null, defaultBoard), isTrue);
  });

  test('paid items need a grant, and a refund takes them back', () async {
    expect(await service.owns('u1', 'dice_gold'), isFalse);
    await service.grant('u1', 'dice_gold', source: 'purchase:GPA.1');
    expect(await service.owns('u1', 'dice_gold'), isTrue);
    expect(await service.owns('u2', 'dice_gold'), isFalse);
    expect(await service.owns(null, 'dice_gold'), isFalse);
    await service.revoke('u1', 'dice_gold');
    expect(await service.owns('u1', 'dice_gold'), isFalse);
  });

  test('unknown items cannot be owned or granted', () async {
    expect(await service.owns('u1', 'dice_hacked'), isFalse);
    expect(
      () => service.grant('u1', 'dice_hacked', source: 'x'),
      throwsArgumentError,
    );
  });

  test('dice skin falls back to the default unless owned and a dice', () async {
    await service.grant('u1', 'board_jungle', source: 'promo');
    expect(await service.resolveDiceSkin('u1', 'dice_gold'), defaultDiceSkin);
    expect(await service.resolveDiceSkin('u1', 'board_jungle'), defaultDiceSkin);
    expect(await service.resolveDiceSkin('u1', 42), defaultDiceSkin);
    await service.grant('u1', 'dice_gold', source: 'purchase:GPA.2');
    expect(await service.resolveDiceSkin('u1', 'dice_gold'), 'dice_gold');
  });
}
