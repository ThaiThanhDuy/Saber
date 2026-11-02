part of 'editor_image.dart';

class PdfEditorImage extends EditorImage {
  Uint8List? pdfBytes;

  /// The index of the relevant page in the [_pdfDocument].
  /// The first page is 0.
  final int pdfPage;

  /// If the pdf needs to be loaded from disk, this is the path (relative to
  /// [FileManager.documentsDirectory]) that the pdf will be loaded from.
  /// Used when this pdf is an asset that already belongs to this note.
  final String? pdfRelPath;

  /// An external file (outside of Saber's own storage) that this pdf's
  /// bytes came from, e.g. one the user just picked to import. Read
  /// directly via `dart:io` (never through [FileManager], since it isn't
  /// under [FileManager.documentsDirectory]).
  final File? externalSourceFile;

  final _pdfDocument = ValueNotifier<PdfDocument?>(null);

  static final log = Logger('PdfEditorImage');

  new({
    required super.id,
    required super.assetCache,
    required this.pdfBytes,
    required this.pdfRelPath,
    this.externalSourceFile,
    required this.pdfPage,
    required super.pageIndex,
    required super.pageSize,
    super.invertible,
    super.backgroundFit,
    required super.onMoveImage,
    required super.onDeleteImage,
    required super.onMiscChange,
    super.onLoad,
    super.newImage,
    super.dstRect,
    required super.naturalSize,
    super.isThumbnail,
  }) : assert(
         !naturalSize.isEmpty,
         'naturalSize must be set for PdfEditorImage',
       ),
       assert(
         pdfBytes != null || pdfRelPath != null || externalSourceFile != null,
         'pdfRelPath or externalSourceFile must be set if pdfBytes is null',
       ),
       super(extension: '.pdf', srcRect: .zero);

  factory fromJson(
    Map<String, dynamic> json, {
    required List<Uint8List>? inlineAssets,
    bool isThumbnail = false,
    required String sbnPath,
    required AssetCache assetCache,
  }) {
    final extension = json['e'] as String?;
    assert(extension == null || extension == '.pdf');

    final assetIndex = json['a'] as int?;
    final Uint8List? pdfBytes;
    String? pdfRelPath;
    if (assetIndex != null) {
      if (inlineAssets == null) {
        pdfRelPath = '$sbnPath${Editor.extension}.$assetIndex';
        pdfBytes = assetCache.get(pdfRelPath);
      } else {
        pdfBytes = inlineAssets[assetIndex];
      }
    } else {
      if (kDebugMode) {
        throw Exception('PdfEditorImage.fromJson: pdf bytes not found');
      }
      pdfBytes = Uint8List(0);
    }

    return PdfEditorImage(
      id:
          json['id'] ??
          -1, // -1 will be replaced by EditorCoreInfo._handleEmptyImageIds()
      assetCache: assetCache,
      pdfBytes: pdfBytes,
      pdfRelPath: pdfRelPath,
      pdfPage: json['pdfi'],
      pageIndex: json['i'] ?? 0,
      pageSize: .infinite,
      invertible: json['v'] ?? true,
      backgroundFit: json['f'] != null ? .values[json['f']] : .contain,
      onMoveImage: null,
      onDeleteImage: null,
      onMiscChange: null,
      onLoad: null,
      newImage: false,
      dstRect: .fromLTWH(
        json['x'] ?? 0,
        json['y'] ?? 0,
        json['w'] ?? 0,
        json['h'] ?? 0,
      ),
      naturalSize: Size(json['nw'] ?? 0, json['nh'] ?? 0),
      isThumbnail: isThumbnail,
    );
  }

  @override
  Map<String, dynamic> toJson(OrderedAssetCache assets) {
    final json = super.toJson(assets);

    // remove non-pdf fields
    json.remove('t'); // thumbnail bytes
    assert(!json.containsKey('a'));
    assert(!json.containsKey('b'));

    json['a'] = assets.add(
      externalSourceFile ??
          (pdfRelPath != null ? NoteAssetPath(pdfRelPath!) : pdfBytes!),
    );
    json['pdfi'] = pdfPage;

    return json;
  }

  @override
  Future<void> firstLoad() async {
    assert(srcRect.isEmpty);
    assert(!naturalSize.isEmpty);

    if (dstRect.isEmpty) {
      final dstSize = pageSize != null
          ? EditorImage.resize(naturalSize, pageSize!)
          : naturalSize;
      dstRect = dstRect.topLeft & dstSize;
    }

    assert(id != -1, 'id must be set before firstLoad is called');
    if (externalSourceFile == null) {
      // Always supply the bytes ourselves (via [FileManager], which knows
      // how to read from either a real path or a SAF tree) rather than
      // letting [PdfDocumentCache] fall back to opening [pdfRelPath] itself
      // with `dart:io`.
      pdfBytes ??= await FileManager.readFile(pdfRelPath!);
    }
    _pdfDocument.value ??= await assetCache.pdfDocumentCache.load(
      externalSourceFile?.path ?? pdfRelPath ?? 'inline_pdf_$id.pdf',
      pdfBytes: pdfBytes,
    );
    await _pdfDocument.value!.pages[pdfPage].ensureLoaded();
  }

  @override
  Future<void> loadIn() async => await super.loadIn();

  @override
  Future<bool> loadOut() async => await super.loadOut();

  @override
  Future<void> precache(BuildContext context) async {
    if (_pdfDocument.value != null) return;

    final completer = Completer<void>();

    void onDocumentSet() {
      if (_pdfDocument.value == null) return;
      if (completer.isCompleted) return;
      completer.complete();
      _pdfDocument.removeListener(onDocumentSet);
    }

    _pdfDocument.addListener(onDocumentSet);
    return completer.future;
  }

  @override
  Widget buildImageWidget({
    required BuildContext context,
    required BoxFit? overrideBoxFit,
    required bool isBackground,
    required bool invert,
  }) {
    return ValueListenableBuilder(
      valueListenable: _pdfDocument,
      builder: (context, pdfDocument, child) {
        if (pdfDocument == null) {
          return SizedBox.fromSize(size: srcRect.size);
        }
        return InvertWidget(
          invert: invert,
          child: PdfPageView(
            document: pdfDocument,
            // [PdfPageView.pageNumber] starts at 1 not 0
            pageNumber: pdfPage + 1,
            decoration: const BoxDecoration(),
          ),
        );
      },
    );
  }

  @override
  PdfEditorImage copy() => PdfEditorImage(
    id: id,
    assetCache: assetCache,
    pdfBytes: pdfBytes,
    pdfPage: pdfPage,
    pdfRelPath: pdfRelPath,
    externalSourceFile: externalSourceFile,
    pageIndex: pageIndex,
    pageSize: .infinite,
    invertible: invertible,
    backgroundFit: backgroundFit,
    onMoveImage: onMoveImage,
    onDeleteImage: onDeleteImage,
    onMiscChange: onMiscChange,
    onLoad: onLoad,
    newImage: true,
    dstRect: dstRect,
    naturalSize: naturalSize,
    isThumbnail: isThumbnail,
  );

  @override
  void dispose() {
    pdfBytes = null;
    _pdfDocument.dispose();
    super.dispose();
  }
}
