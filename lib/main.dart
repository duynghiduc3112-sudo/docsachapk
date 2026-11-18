import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epub_view/epub_view.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EbookReaderApp());
}

class EbookReaderApp extends StatelessWidget {
  const EbookReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tủ Sách Cá Nhân',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5D4037)),
        useMaterial3: true,
      ),
      home: const BookshelfScreen(),
    );
  }
}

// --- MÔ HÌNH DỮ LIỆU BOOKMARK ---
class BookmarkItem {
  final String id;
  final String label;
  final String location; // CFI cho EPUB hoặc số trang cho PDF
  final String createdAt;

  BookmarkItem({
    required this.id,
    required this.label,
    required this.location,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'location': location,
        'createdAt': createdAt,
      };

  factory BookmarkItem.fromJson(Map<String, dynamic> json) => BookmarkItem(
        id: json['id'],
        label: json['label'],
        location: json['location'],
        createdAt: json['createdAt'],
      );
}

// --- MÔ HÌNH DỮ LIỆU SÁCH ---
class BookItem {
  final String id;
  String title;
  final String filePath;
  final String extension;
  String? coverPath;
  int readingSeconds;
  String? lastLocation;
  List<BookmarkItem> bookmarks;

  BookItem({
    required this.id,
    required this.title,
    required this.filePath,
    required this.extension,
    this.coverPath,
    this.readingSeconds = 0,
    this.lastLocation,
    List<BookmarkItem>? bookmarks,
  }) : bookmarks = bookmarks ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'filePath': filePath,
        'extension': extension,
        'coverPath': coverPath,
        'readingSeconds': readingSeconds,
        'lastLocation': lastLocation,
        'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
      };

  factory BookItem.fromJson(Map<String, dynamic> json) => BookItem(
        id: json['id'],
        title: json['title'],
        filePath: json['filePath'],
        extension: json['extension'],
        coverPath: json['coverPath'],
        readingSeconds: json['readingSeconds'] ?? 0,
        lastLocation: json['lastLocation'],
        bookmarks: (json['bookmarks'] as List<dynamic>?)
                ?.map((b) => BookmarkItem.fromJson(b))
                .toList() ??
            [],
      );
}

// --- MÀN HÌNH KỆ SÁCH ---
class BookshelfScreen extends StatefulWidget {
  const BookshelfScreen({super.key});

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  List<BookItem> _books = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final String? booksJson = prefs.getString('saved_books_v2');
    if (booksJson != null) {
      final List<dynamic> decoded = jsonDecode(booksJson);
      setState(() {
        _books = decoded.map((e) => BookItem.fromJson(e)).toList();
      });
    }
  }

  Future<void> _saveBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_books.map((e) => e.toJson()).toList());
    await prefs.setString('saved_books_v2', encoded);
  }

  // Tự động trích xuất ảnh bìa từ file EPUB nếu có
  Future<String?> _extractEpubCover(File epubFile, String bookId, String appDirPath) async {
    try {
      final bytes = await epubFile.readAsBytes();
      final epubBook = await EpubReader.readBook(bytes);
      final coverImage = epubBook.CoverImage;
      if (coverImage != null) {
        final pngBytes = encodePng(coverImage);
        final coverFile = File('$appDirPath/cover_$bookId.png');
        await coverFile.writeAsBytes(pngBytes);
        return coverFile.path;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _pickAndAddBook() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub', 'pdf'],
    );

    if (result != null && result.files.single.path != null) {
      setState(() => _isLoading = true);

      try {
        File sourceFile = File(result.files.single.path!);
        String fileName = result.files.single.name;
        String ext = fileName.split('.').last.toLowerCase();
        String title = fileName.replaceAll(RegExp(r'\.(epub|pdf)$', caseSensitive: false), '');

        final appDir = await getApplicationDocumentsDirectory();
        final String id = DateTime.now().millisecondsSinceEpoch.toString();
        final String savedPath = '${appDir.path}/$id.$ext';
        final File savedFile = await sourceFile.copy(savedPath);

        String? coverPath;
        if (ext == 'epub') {
          coverPath = await _extractEpubCover(savedFile, id, appDir.path);
        }

        final newBook = BookItem(
          id: id,
          title: title,
          filePath: savedPath,
          extension: ext,
          coverPath: coverPath,
        );

        setState(() {
          _books.insert(0, newBook);
        });
        await _saveBooks();
      } finally {
        setState(() => _isLoading = false);
      }
    }
  }

  // Cho phép người dùng tự chọn ảnh bìa từ thư viện điện thoại
  Future<void> _changeBookCover(BookItem book) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);

    if (image != null) {
      final appDir = await getApplicationDocumentsDirectory();
      final String newCoverPath = '${appDir.path}/custom_cover_${book.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(image.path).copy(newCoverPath);

      setState(() {
        book.coverPath = newCoverPath;
      });
      await _saveBooks();
    }
  }

  // Đổi tên sách
  Future<void> _renameBook(BookItem book) async {
    final controller = TextEditingController(text: book.title);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Đổi tên sách'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty) {
      setState(() => book.title = newName);
      await _saveBooks();
    }
  }

  Future<void> _deleteBook(BookItem book) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa sách?'),
        content: Text('Bạn có chắc muốn xóa "${book.title}" khỏi tủ sách?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final file = File(book.filePath);
      if (await file.exists()) await file.delete();
      if (book.coverPath != null) {
        final cover = File(book.coverPath!);
        if (await cover.exists()) await cover.delete();
      }
      setState(() {
        _books.removeWhere((b) => b.id == book.id);
      });
      await _saveBooks();
    }
  }

  String _formatDuration(int totalSeconds) {
    if (totalSeconds < 60) return '$totalSeconds giây';
    int hours = totalSeconds ~/ 3600;
    int minutes = (totalSeconds % 3600) ~/ 60;
    if (hours > 0) return '$hours giờ $minutes phút';
    return '$minutes phút';
  }

  int get _totalReadingSeconds =>
      _books.fold(0, (sum, item) => sum + item.readingSeconds);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F5F0),
      appBar: AppBar(
        title: const Text('Tủ Sách Cá Nhân', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFFF7F5F0),
        elevation: 0,
      ),
      body: Column(
        children: [
          // Thống kê tổng quan
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF5D4037),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(
                  children: [
                    Text(
                      '${_books.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const Text('Cuốn sách', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ],
                ),
                Container(height: 30, width: 1, color: Colors.white24),
                Column(
                  children: [
                    Text(
                      _formatDuration(_totalReadingSeconds),
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const Text('Tổng thời gian đọc', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ],
                ),
              ],
            ),
          ),

          if (_isLoading) const LinearProgressIndicator(),

          // Danh sách sách kèm ảnh bìa
          Expanded(
            child: _books.isEmpty
                ? const Center(
                    child: Text(
                      'Tủ sách đang trống.\nBấm "+ Thêm sách" để nhập file EPUB hoặc PDF.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 15),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                    itemCount: _books.length,
                    itemBuilder: (context, index) {
                      final book = _books[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        elevation: 1,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ReaderScreen(
                                  book: book,
                                  onSaveProgress: _saveBooks,
                                ),
                              ),
                            );
                            setState(() {});
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                // Ảnh bìa sách
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: book.coverPath != null && File(book.coverPath!).existsSync()
                                      ? Image.file(
                                          File(book.coverPath!),
                                          width: 56,
                                          height: 80,
                                          fit: BoxFit.cover,
                                        )
                                      : Container(
                                          width: 56,
                                          height: 80,
                                          color: book.extension == 'epub'
                                              ? Colors.teal.shade700
                                              : Colors.red.shade700,
                                          alignment: Alignment.center,
                                          child: Text(
                                            book.extension.toUpperCase(),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                ),
                                const SizedBox(width: 14),
                                // Thông tin sách
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        book.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          const Icon(Icons.timer_outlined, size: 15, color: Colors.brown),
                                          const SizedBox(width: 4),
                                          Text(
                                            _formatDuration(book.readingSeconds),
                                            style: const TextStyle(color: Colors.brown, fontSize: 13),
                                          ),
                                          const SizedBox(width: 12),
                                          const Icon(Icons.bookmark_outline, size: 15, color: Colors.grey),
                                          const SizedBox(width: 2),
                                          Text(
                                            '${book.bookmarks.length}',
                                            style: const TextStyle(color: Colors.grey, fontSize: 13),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                // Menu tùy chọn (Đổi bìa, Đổi tên, Xóa)
                                PopupMenuButton<String>(
                                  onSelected: (val) {
                                    if (val == 'cover') _changeBookCover(book);
                                    if (val == 'rename') _renameBook(book);
                                    if (val == 'delete') _deleteBook(book);
                                  },
                                  itemBuilder: (ctx) => [
                                    const PopupMenuItem(
                                      value: 'cover',
                                      child: Row(
                                        children: [
                                          Icon(Icons.image_outlined, size: 20),
                                          SizedBox(width: 8),
                                          Text('Chọn ảnh bìa'),
                                        ],
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'rename',
                                      child: Row(
                                        children: [
                                          Icon(Icons.edit_outlined, size: 20),
                                          SizedBox(width: 8),
                                          Text('Đổi tên sách'),
                                        ],
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Row(
                                        children: [
                                          Icon(Icons.delete_outline, color: Colors.red, size: 20),
                                          SizedBox(width: 8),
                                          Text('Xóa sách', style: TextStyle(color: Colors.red)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pickAndAddBook,
        backgroundColor: const Color(0xFF5D4037),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Thêm sách'),
      ),
    );
  }
}

// --- MÀN HÌNH ĐỌC SÁCH ---
class ReaderScreen extends StatefulWidget {
  final BookItem book;
  final Future<void> Function() onSaveProgress;

  const ReaderScreen({
    super.key,
    required this.book,
    required this.onSaveProgress,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _timer;
  bool _isPaused = false;
  int _sessionSeconds = 0;

  double _fontSize = 18.0;
  int _themeIndex = 1; // 0: Trắng, 1: Vàng giấy cũ, 2: Tối

  final List<Color> _bgColors = [
    Colors.white,
    const Color(0xFFF4ECD8),
    const Color(0xFF1A1A1A),
  ];

  final List<Color> _textColors = [
    Colors.black87,
    const Color(0xFF3B2F2F),
    const Color(0xFFD0D0D0),
  ];

  EpubController? _epubController;
  final PdfViewerController _pdfController = PdfViewerController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initReader();
    _startTimer();
  }

  void _initReader() {
    if (widget.book.extension == 'epub') {
      _epubController = EpubController(
        document: EpubDocument.openFile(File(widget.book.filePath)),
        epubCfi: widget.book.lastLocation,
      );
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isPaused && mounted) {
        setState(() {
          _sessionSeconds++;
          widget.book.readingSeconds++;
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _isPaused = true;
      _saveCurrentState();
    } else if (state == AppLifecycleState.resumed) {
      _isPaused = false;
    }
  }

  Future<void> _saveCurrentState() async {
    if (widget.book.extension == 'epub' && _epubController != null) {
      widget.book.lastLocation = _epubController!.generateEpubCfi();
    } else if (widget.book.extension == 'pdf' && _pdfController.isReady) {
      widget.book.lastLocation = _pdfController.pageNumber.toString();
    }
    await widget.onSaveProgress();
  }

  // Thêm dấu trang (Bookmark) tại vị trí đang đọc
  Future<void> _addBookmark() async {
    String? location;
    String defaultLabel = '';

    if (widget.book.extension == 'epub' && _epubController != null) {
      location = _epubController!.generateEpubCfi();
      final chapterTitle = _epubController!.currentValue?.chapter?.Title?.trim();
      defaultLabel = (chapterTitle != null && chapterTitle.isNotEmpty)
          ? chapterTitle
          : 'Vị trí đánh dấu #${widget.book.bookmarks.length + 1}';
    } else if (widget.book.extension == 'pdf' && _pdfController.isReady) {
      final page = _pdfController.pageNumber ?? 1;
      location = page.toString();
      defaultLabel = 'Trang $page';
    }

    if (location == null) return;

    final now = DateTime.now();
    final timeStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final bookmark = BookmarkItem(
      id: now.millisecondsSinceEpoch.toString(),
      label: defaultLabel,
      location: location,
      createdAt: timeStr,
    );

    setState(() {
      widget.book.bookmarks.insert(0, bookmark);
    });
    await widget.onSaveProgress();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã đánh dấu: $defaultLabel'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // Mở danh sách Bookmark để nhảy tới hoặc xóa
  void _showBookmarksSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Danh sách Dấu trang (Bookmarks)',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(height: 1),
              if (widget.book.bookmarks.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('Chưa có dấu trang nào được lưu.'),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: widget.book.bookmarks.length,
                    itemBuilder: (context, index) {
                      final bm = widget.book.bookmarks[index];
                      return ListTile(
                        leading: const Icon(Icons.bookmark, color: Color(0xFF5D4037)),
                        title: Text(bm.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('Lưu lúc: ${bm.createdAt}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.grey),
                          onPressed: () async {
                            setState(() => widget.book.bookmarks.removeAt(index));
                            setModalState(() {});
                            await widget.onSaveProgress();
                          },
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          if (widget.book.extension == 'epub' && _epubController != null) {
                            _epubController!.gotoEpubCfi(bm.location);
                          } else if (widget.book.extension == 'pdf' && _pdfController.isReady) {
                            final page = int.tryParse(bm.location);
                            if (page != null) _pdfController.goToPage(pageNumber: page);
                          }
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _saveCurrentState();
    _epubController?.dispose();
    super.dispose();
  }

  String _formatSessionTime(int sec) {
    int m = sec ~/ 60;
    int s = sec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = _bgColors[_themeIndex];
    final textColor = _textColors[_themeIndex];

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: bgColor,
      // Drawer Mục lục chương cho EPUB
      drawer: widget.book.extension == 'epub' && _epubController != null
          ? Drawer(
              child: SafeArea(
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Mục Lục Chương',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: EpubViewTableOfContents(controller: _epubController!),
                    ),
                  ],
                ),
              ),
            )
          : null,
      appBar: AppBar(
        backgroundColor: bgColor,
        foregroundColor: textColor,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.book.title,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: textColor),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              'Phiên đọc: ${_formatSessionTime(_sessionSeconds)}',
              style: TextStyle(fontSize: 12, color: textColor.withOpacity(0.7)),
            ),
          ],
        ),
        actions: [
          // Mở Mục lục chương (cho EPUB)
          if (widget.book.extension == 'epub')
            IconButton(
              icon: const Icon(Icons.toc),
              tooltip: 'Mục lục',
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
          // Thêm Bookmark
          IconButton(
            icon: const Icon(Icons.bookmark_add_outlined),
            tooltip: 'Đánh dấu trang này',
            onPressed: _addBookmark,
          ),
          // Xem danh sách Bookmark
          IconButton(
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: 'Danh sách dấu trang',
            onPressed: _showBookmarksSheet,
          ),
        ],
      ),
      body: widget.book.extension == 'epub'
          ? EpubView(
              controller: _epubController!,
              builders: EpubViewBuilders<DefaultBuilderOptions>(
                options: DefaultBuilderOptions(
                  textStyle: TextStyle(
                    fontSize: _fontSize,
                    height: 1.6,
                    color: textColor,
                  ),
                ),
              ),
            )
          : ColorFiltered(
              colorFilter: _themeIndex == 2
                  ? const ColorFilter.matrix([
                      -1, 0, 0, 0, 255,
                      0, -1, 0, 0, 255,
                      0, 0, -1, 0, 255,
                      0, 0, 0, 1, 0,
                    ])
                  : const ColorFilter.mode(Colors.transparent, BlendMode.multiply),
              child: PdfViewer.file(
                widget.book.filePath,
                controller: _pdfController,
                params: PdfViewerParams(
                  pageNumber: int.tryParse(widget.book.lastLocation ?? '1') ?? 1,
                  backgroundColor: bgColor,
                ),
              ),
            ),
      // Thanh công cụ dưới cùng: Phóng to / Thu nhỏ & Đổi màu nền
      bottomNavigationBar: Container(
        color: bgColor,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: SafeArea(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: Icon(Icons.text_decrease, color: textColor),
                tooltip: 'Thu nhỏ',
                onPressed: () {
                  setState(() {
                    if (widget.book.extension == 'epub') {
                      if (_fontSize > 12) _fontSize -= 2;
                    } else if (_pdfController.isReady) {
                      _pdfController.zoomDown();
                    }
                  });
                },
              ),
              if (widget.book.extension == 'epub')
                Text(
                  '${_fontSize.toInt()} pt',
                  style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
                ),
              IconButton(
                icon: Icon(Icons.text_increase, color: textColor),
                tooltip: 'Phóng to',
                onPressed: () {
                  setState(() {
                    if (widget.book.extension == 'epub') {
                      if (_fontSize < 34) _fontSize += 2;
                    } else if (_pdfController.isReady) {
                      _pdfController.zoomUp();
                    }
                  });
                },
              ),
              const SizedBox(width: 16),
              // 3 nút chọn nhanh màu nền
              _buildThemeDot(0, Colors.white, 'Sáng'),
              _buildThemeDot(1, const Color(0xFFF4ECD8), 'Giấy cũ'),
              _buildThemeDot(2, const Color(0xFF1A1A1A), 'Tối'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThemeDot(int index, Color color, String tooltip) {
    final isSelected = _themeIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _themeIndex = index),
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? Colors.brown : Colors.grey.shade400,
              width: isSelected ? 2.5 : 1,
            ),
          ),
        ),
      ),
    );
  }
}
