import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

void main() {
  final repoRoot = Directory.current.path;
  final skillsDir = Directory(p.join(repoRoot, 'skills'));
  final outputFile = File(p.join(repoRoot, 'lib', 'src', 'skills_data.dart'));

  if (!skillsDir.existsSync()) {
    stderr.writeln('Error: skills directory not found at ${skillsDir.path}');
    exit(1);
  }

  final skills = <String, String>{};
  final dirEntities = skillsDir.listSync();

  for (final entity in dirEntities) {
    if (entity is Directory) {
      final skillFile = File(p.join(entity.path, 'SKILL.md'));
      if (skillFile.existsSync()) {
        final folderName = p.basename(entity.path);
        // Normalize name: replace hyphens with underscores for the Dart map key
        final category = folderName.replaceAll('-', '_');
        var content = skillFile.readAsStringSync(encoding: utf8);

        skills[category] = content;
      }
    }
  }

  final buffer = StringBuffer()
    ..writeln('// Generated file. Do not edit manually.')
    ..writeln()
    ..writeln('const Map<String, String> mcpSkillsData = {');

  skills.forEach((category, content) {
    // Escape dollar signs to avoid Dart string interpolation issues
    final escapedContent = content.replaceAll(r'$', r'\$');
    buffer.writeln("  '$category': '''$escapedContent''',");
  });

  buffer.writeln('};');

  outputFile.parent.createSync(recursive: true);
  outputFile.writeAsStringSync(buffer.toString(), encoding: utf8);

  print(
      'Successfully generated ${outputFile.path} with ${skills.length} skills.');
}
