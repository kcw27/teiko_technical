import pandas as pd
import sqlite3
import os

script_path = os.path.abspath(__file__)
os.chdir(os.path.dirname(script_path)) # this script will be located at the root, so files are created relative to that

connection = sqlite3.connect("patient_data.db") # must be located in the repository root
cursor = connection.cursor()

# if previously ran, delete tables so this can be run multiple times with no issue
cursor.execute("DROP TABLE IF EXISTS metadata")
cursor.execute("DROP TABLE IF EXISTS summary")

cursor.execute(
    """
    CREATE TABLE metadata (
        project TEXT,
        subject TEXT,
        condition TEXT,
        age INTEGER,
        sex TEXT,
        treatment TEXT,
        response TEXT,
        sample TEXT PRIMARY KEY,
        sample_type TEXT,
        time_from_treatment_start INTEGER,
        b_cell INTEGER,
        cd8_t_cell INTEGER,
        cd4_t_cell INTEGER,
        nk_cell INTEGER,
        monocyte INTEGER
    )
"""
)

chunks = pd.read_csv("data/cell-count.csv", chunksize=10000)

print("Loading data into database...")
for df in chunks:
    print(f"Processing chunk with shape {df.shape}")
    df.to_sql("metadata", connection, if_exists="append", index=False)
print("Done writing to data/patient_data.db")

connection.commit()
connection.close()