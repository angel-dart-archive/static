import 'dart:async';
import 'package:angel_framework/angel_framework.dart';
import 'package:file/file.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

final RegExp _param = new RegExp(r':([A-Za-z0-9_]+)(\((.+)\))?');
final RegExp _straySlashes = new RegExp(r'(^/+)|(/+$)');

String _pathify(String path) {
  var p = path.replaceAll(_straySlashes, '');

  Map<String, String> replace = {};

  for (Match match in _param.allMatches(p)) {
    if (match[3] != null) replace[match[0]] = ':${match[1]}';
  }

  replace.forEach((k, v) {
    p = p.replaceAll(k, v);
  });

  return p;
}

/// A static server plug-in.
class VirtualDirectory {
  String _prefix;
  Directory _source;

  /// The directory to serve files from.
  Directory get source => _source;

  /// An optional callback to run before serving files.
  final Function(File file, RequestContext req, ResponseContext res) callback;

  final Angel app;
  final FileSystem fileSystem;

  /// Filenames to be resolved within directories as indices.
  final Iterable<String> indexFileNames;

  /// An optional public path to map requests to.
  final String publicPath;

  /// If `true` (default: `false`), then if a directory does not contain any of the specific [indexFileNames], a default directory listing will be served.
  final bool allowDirectoryListing;

  VirtualDirectory(this.app, this.fileSystem,
      {Directory source,
      this.indexFileNames: const ['index.html'],
      this.publicPath: '/',
      this.callback,
      this.allowDirectoryListing: false}) {
    _prefix = publicPath.replaceAll(_straySlashes, '');
    if (source != null) {
      _source = source;
    } else {
      String dirPath = app.isProduction ? './build/web' : './web';
      _source = fileSystem.directory(dirPath);
    }
  }

  /// Responds to incoming HTTP requests.
  Future<bool> handleRequest(RequestContext req, ResponseContext res) {
    if (req.method != 'GET') return new Future<bool>.value(true);
    var path = req.path.replaceAll(_straySlashes, '');

    if (_prefix?.isNotEmpty == true && !path.startsWith(_prefix))
      return new Future<bool>.value(true);

    return servePath(path, req, res);
  }

  /// A handler that serves the file at the given path, unless the user has requested that path.
  ///
  /// You can also limit this functionality to specific values of the `Accept` header, ex. `text/html`.
  /// If [accepts] is `null`, OR at least one of the content types in [accepts] is present,
  /// the view will be served.
  RequestMiddleware pushState(String path, {Iterable accepts}) {
    var vPath = path.replaceAll(_straySlashes, '');
    if (_prefix?.isNotEmpty == true) vPath = '$_prefix/$vPath';

    return (RequestContext req, ResponseContext res) {
      var path = req.path.replaceAll(_straySlashes, '');
      if (path == vPath) return new Future<bool>.value(true);

      if (accepts?.isNotEmpty == true) {
        if (!accepts.any((x) => req.accepts(x, strict: true))) return new Future<bool>.value(true);
      }

      return servePath(vPath, req, res);
    };
  }

  /// Writes the file at the given virtual [path] to a response.
  Future<bool> servePath(
      String path, RequestContext req, ResponseContext res) async {
    if (_prefix.isNotEmpty) {
      // Only replace the *first* incidence
      // Resolve: https://github.com/angel-dart/angel/issues/41
      path = path.replaceFirst(new RegExp('^' + _pathify(_prefix)), '');
    }

    if (path.isEmpty) path = '.';
    path = path.replaceAll(_straySlashes, '');

    var absolute = source.absolute.uri.resolve(path).toFilePath();
    var stat = await fileSystem.stat(absolute);
    return await serveStat(absolute, path, stat, req, res);
  }

  /// Writes the file at the path given by the [stat] to a response.
  Future<bool> serveStat(String absolute, String relative, FileStat stat, RequestContext req,
      ResponseContext res) async {
    if (stat.type == FileSystemEntityType.DIRECTORY)
      return await serveDirectory(
          fileSystem.directory(absolute), relative, stat, req, res);
    else if (stat.type == FileSystemEntityType.FILE)
      return await serveFile(fileSystem.file(absolute), stat, req, res);
    else if (stat.type == FileSystemEntityType.LINK) {
      var link = fileSystem.link(absolute);
      return await servePath(await link.resolveSymbolicLinks(), req, res);
    } else
      return true;
  }

  /// Serves the index file of a [directory], if it exists.
  Future<bool> serveDirectory(Directory directory, String relative, FileStat stat,
      RequestContext req, ResponseContext res) async {
    for (String indexFileName in indexFileNames) {
      final index =
          fileSystem.file(directory.absolute.uri.resolve(indexFileName));
      if (await index.exists()) {
        return await serveFile(index, stat, req, res);
      }
    }

    if (allowDirectoryListing == true) {
      res.headers['content-type'] = 'text/html';
      res
        ..write('<!DOCTYPE html>')
        ..write('<html>')
        ..write(
            '<head><meta name="viewport" content="width=device-width,initial-scale=1">')
        ..write('<style>ul { list-style-type: none; }</style>')
        ..write('</head></html><body>');

      res.write('<li><a href="..">..</a></li>');

      List<FileSystemEntity> entities = await directory
          .list(followLinks: false)
          .toList()
          .then((l) => new List.from(l));
      entities.sort((a, b) {
        if (a is Directory) {
          if (b is Directory) return a.path.compareTo(b.path);
          return -1;
        } else if (a is File) {
          if (b is Directory)
            return 1;
          else if (b is File) return a.path.compareTo(b.path);
          return -1;
        } else if (b is Link) return a.path.compareTo(b.path);

        return 1;
      });

      for (var entity in entities) {
        var stub = p.basename(entity.path);
        var href = stub;
        String type;

        if (entity is File)
          type = '[File]';
        else if (entity is Directory)
          type = '[Directory]';
        else if (entity is Link) type = '[Link]';

        if (relative.isNotEmpty)
          href = '/' +  relative + '/' + stub;

        if (entity is Directory)
          href += '/';

        res.write('<li><a href="$href">$type $stub</a></li>');
      }

      res..write('</body></html>');
      return false;
    }

    return true;
  }

  void _ensureContentTypeAllowed(String mimeType, RequestContext req) {
    var value = req.headers.value('accept');
    bool acceptable = value == null ||
        value?.isNotEmpty != true ||
        (mimeType?.isNotEmpty == true && value?.contains(mimeType) == true) ||
        value?.contains('*/*') == true;
    if (!acceptable)
      throw new AngelHttpException(
          new UnsupportedError(
              'Client requested $value, but server wanted to send $mimeType.'),
          statusCode: 406,
          message: '406 Not Acceptable');
  }

  /// Writes the contents of a file to a response.
  Future<bool> serveFile(
      File file, FileStat stat, RequestContext req, ResponseContext res) async {
    res.statusCode = 200;

    if (callback != null) {
      var r = callback(file, req, res);
      r = r is Future ? await r : r;
      if (r != null && r != true) return r;
    }

    var type = lookupMimeType(file.path) ?? 'application/octet-stream';
    _ensureContentTypeAllowed(type, req);
    res.headers['content-type'] = type;

    await file.openRead().pipe(res);
    return false;
  }
}
