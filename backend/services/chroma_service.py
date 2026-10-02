import chromadb
import os

CHROMA_DATA_PATH = os.path.join(os.path.dirname(__file__), "..", "chroma_data")
client = chromadb.PersistentClient(path=CHROMA_DATA_PATH)
collection = client.get_or_create_collection(name="medicine_kb")

def init_medicine_db():
    if collection.count() > 0:
        return
    
    medicines = [
        {"id": "med_1", "name": "阿司匹林肠溶片", "category": "心血管药", "usage": "饭后服用，减少胃肠道刺激", "fatalWarning": "有胃溃疡病史者禁用。"},
        {"id": "med_2", "name": "阿莫西林胶囊", "category": "抗生素", "usage": "按医嘱按时服用", "fatalWarning": "青霉素过敏者绝对禁用！"},
        {"id": "med_3", "name": "头孢克肟", "category": "抗生素", "usage": "饭前或饭后服用均可", "fatalWarning": "服药期间及停药后7天内禁止饮酒，可能发生严重的双硫仑样反应致死！"},
        {"id": "med_4", "name": "布洛芬缓释胶囊", "category": "解热镇痛药", "usage": "发热或疼痛时服用", "fatalWarning": "不能与其他退烧感冒药同服，以免过量导致肝损伤。"},
        {"id": "med_5", "name": "复方感冒灵", "category": "感冒药", "usage": "按说明书服用，服药后易困倦", "fatalWarning": "含有对乙酰氨基酚，严禁与布洛芬等退烧药叠加使用。"}
    ]
    
    ids = [med["id"] for med in medicines]
    documents = [f"{med['name']} {med['category']} {med['usage']} {med['fatalWarning']}" for med in medicines]
    metadatas = [
        {
            "name": med["name"], 
            "category": med["category"], 
            "usage": med["usage"], 
            "fatalWarning": med["fatalWarning"]
        } for med in medicines
    ]
    
    collection.add(
        documents=documents,
        metadatas=metadatas,
        ids=ids
    )

def search_medicine_in_db(query: str, n_results: int = 1):
    init_medicine_db()
    results = collection.query(
        query_texts=[query],
        n_results=n_results
    )
    if results and results["metadatas"] and len(results["metadatas"]) > 0 and len(results["metadatas"][0]) > 0:
        return results["metadatas"][0][0]
    return None
