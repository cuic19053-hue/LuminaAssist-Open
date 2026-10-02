const fs = require('fs');
let content = fs.readFileSync('entry/src/main/ets/utils/DatabaseUtil.ets', 'utf-8');

const interfaceDef = `\ninterface EmergencyMed {\n  name: string;\n  category: string;\n  usage: string;\n  fatalWarning: string;\n}\n`;
content = content.replace('export class DatabaseUtil {', interfaceDef + '\nexport class DatabaseUtil {');

content = content.replace(/const emergencyMeds: Array<Record<string, string>> = \[/g, "const emergencyMeds: Array<EmergencyMed> = [");
content = content.replace(/\} as Record<string, string>,/g, "},");
content = content.replace(/\} as Record<string, string>(\r?\n\s*\])/g, "}$1");

fs.writeFileSync('entry/src/main/ets/utils/DatabaseUtil.ets', content, 'utf-8');
console.log('DatabaseUtil patched with interface!');
