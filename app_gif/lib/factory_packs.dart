import 'package:flutter/material.dart';

class FactoryPack {
  const FactoryPack({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.cover,
    required this.materialIds,
  });

  final String id, name, subtitle, cover;
  final List<String> materialIds;
}

// Pack titles are proper names and deliberately stay English in every locale.
const factoryPacks = [
  FactoryPack(
    id: 'sharingan',
    name: 'Sharingan',
    subtitle: "The Uchiha's Cursed Eye",
    cover: 'assets/pack_covers/sharingan.jpg',
    materialIds: [
      'S001',
      'S002',
      'S003',
      'S004',
      'S005',
      'S006',
      'S007',
      'S008',
      'S009',
      'S010',
    ],
  ),
  FactoryPack(
    id: 'faceit',
    name: 'Faceit',
    subtitle: 'The Arena of the Elite',
    cover: 'assets/pack_covers/faceit.jpg',
    materialIds: [
      'F008',
      'F009',
      'F010',
      'F011',
      'F012',
      'F013',
      'F014',
      'F015',
      'F016',
      'F017',
      'F018',
    ],
  ),
];

class FactoryPackBrowser extends StatefulWidget {
  const FactoryPackBrowser({
    super.key,
    required this.availableIds,
    required this.materialBuilder,
    this.enabled = true,
  });

  final Set<String> availableIds;
  final Widget Function(BuildContext context, String id) materialBuilder;
  final bool enabled;

  @override
  State<FactoryPackBrowser> createState() => _FactoryPackBrowserState();
}

class _FactoryPackBrowserState extends State<FactoryPackBrowser> {
  String? _expanded;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: const PageStorageKey('backpack-scroll'),
    slivers: [
      for (final pack in factoryPacks) ...[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          sliver: SliverToBoxAdapter(
            child: _PackCover(
              pack: pack,
              expanded: _expanded == pack.id,
              onTap:
                  widget.enabled &&
                      pack.materialIds.any(widget.availableIds.contains)
                  ? () => setState(() {
                      _expanded = _expanded == pack.id ? null : pack.id;
                    })
                  : null,
            ),
          ),
        ),
        if (_expanded == pack.id)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverGrid.count(
              crossAxisCount: 3,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              children: [
                for (final id in pack.materialIds)
                  if (widget.availableIds.contains(id))
                    widget.materialBuilder(context, id),
              ],
            ),
          ),
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 88)),
    ],
  );
}

class _PackCover extends StatelessWidget {
  const _PackCover({required this.pack, required this.expanded, this.onTap});

  final FactoryPack pack;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    expanded: onTap == null ? null : expanded,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Material(
        color: const Color(0xff101014),
        child: InkWell(
          key: ValueKey('pack-${pack.id}'),
          onTap: onTap,
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          child: LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              height: constraints.maxWidth / 3.2 + 6,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _image(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 12, 18, 17),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pack.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                            shadows: [
                              Shadow(
                                color: Color(0x99000000),
                                blurRadius: 3,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          pack.subtitle,
                          style: const TextStyle(
                            color: Color(0xffccccd2),
                            fontSize: 11,
                            height: 1.3,
                            shadows: [
                              Shadow(
                                color: Color(0x99000000),
                                blurRadius: 3,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _image() => Image.asset(
    pack.cover,
    fit: BoxFit.cover,
    alignment: pack.id == 'faceit'
        ? const Alignment(0, -.45)
        : Alignment.center,
    excludeFromSemantics: true,
    filterQuality: FilterQuality.medium,
  );
}
