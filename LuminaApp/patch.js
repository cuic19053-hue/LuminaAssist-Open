const fs = require('fs');
function patch(file, replacements) {
    let content = fs.readFileSync(file, 'utf-8');
    for (const [search, replace] of replacements) {
        content = content.replace(search, replace);
    }
    fs.writeFileSync(file, content, 'utf-8');
}

patch('entry/src/main/ets/utils/DatabaseUtil.ets', [
    [/const emergencyMeds = \[/, "const emergencyMeds: Array<Record<string, string>> = ["],
    [/fatalWarning: '绝对不可以吞下！' \},/, "fatalWarning: '绝对不可以吞下！' } as Record<string, string>,"],
    [/fatalWarning: '发作时请务必舌下含服，切勿直接吞下！' \}/, "fatalWarning: '发作时请务必舌下含服，切勿直接吞下！' } as Record<string, string>"],
    [/result = \{\s*name: resultSet\.getString\(resultSet\.getColumnIndex\('name'\)\),\s*category: resultSet\.getString\(resultSet\.getColumnIndex\('category'\)\),\s*usage: resultSet\.getString\(resultSet\.getColumnIndex\('usage'\)\),\s*fatalWarning: resultSet\.getString\(resultSet\.getColumnIndex\('fatalWarning'\)\)\s*\};/g, "result = { 'name': resultSet.getString(resultSet.getColumnIndex('name')), 'category': resultSet.getString(resultSet.getColumnIndex('category')), 'usage': resultSet.getString(resultSet.getColumnIndex('usage')), 'fatalWarning': resultSet.getString(resultSet.getColumnIndex('fatalWarning')) } as Record<string, Object>;"]
]);

patch('entry/src/main/ets/utils/ElderlyMedicineKb.ets', [
    [/const data = JSON\.parse\(response\.result as string\);/, "const data = JSON.parse(response.result as string) as Record<string, string>;"],
    [/name: data\.name,/, "name: data['name'],"],
    [/category: data\.category,/, "category: data['category'],"],
    [/usage: data\.usage,/, "usage: data['usage'],"],
    [/fatalWarning: data\.fatalWarning/, "fatalWarning: data['fatalWarning']"],
    [/Logger\.info\(TAG, 【云端命中】返回药品: \\$\\{data\\.name\\}\);/, "Logger.info(TAG, 【云端命中】返回药品: \\);"],
    [/return \{\s*name: data\['name'\],\s*category: data\['category'\],\s*usage: data\['usage'\],\s*fatalWarning: data\['fatalWarning'\]\s*\};/, "return { name: data['name'], category: data['category'], usage: data['usage'], fatalWarning: data['fatalWarning'] } as MedicineKbEntry;"]
]);

patch('entry/src/main/ets/services/AuthService.ets', [
    [/device_id: deviceId/, "'device_id': deviceId"],
    [/const response = await this\.httpClient\.post\('\/api\/v1\/auth\/login', \{\s*'device_id': deviceId\s*\}\) as Record<string, string>;/, "const response = await this.httpClient.post('/api/v1/auth/login', { 'device_id': deviceId } as Record<string, string>) as Record<string, string>;"],
    [/const profile = JSON\.parse\(profileJson\);/, "const profile = JSON.parse(profileJson) as Record<string, Object>;"]
]);

patch('entry/src/main/ets/agent/Agent.ets', [
    [/historyItems\.map\(item => \(\{\s*role: item\.role,\s*text: item\.text\s*\}\) as Record<string, string>\);/, "historyItems.map((item) => { return { 'role': item.role, 'text': item.text } as Record<string, string>; });"]
]);

console.log('Patched again!');
