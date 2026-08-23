# import pandas as pd
import sqlite3
import os

script_path = os.path.abspath(__file__)
os.chdir(os.path.dirname(script_path)) # this script will be located at the root, so files are created relative to that

connection = sqlite3.connect("patient_data.db") # database must be in the repository root
cursor = connection.cursor()

cell_types = ["b_cell", "cd8_t_cell", "cd4_t_cell", "nk_cell", "monocyte"]

# check if the metadata table has the cell type columns; if not, they've already been removed
cursor.execute("PRAGMA table_info('metadata')")
columns_data = cursor.fetchall()
existing_columns = {col[1] for col in columns_data}

if not set(cell_types + ["sample"]).issubset(existing_columns):
    raise Exception(f"Columns missing: {set(cell_types + ["sample"]).difference(existing_columns)}. This may be the case if summarize_data.py is run multiple times in a row. Try rerunning load_data.py first.")

# if previously ran, delete summary table so this can be run multiple times with no issue
cursor.execute("DROP TABLE IF EXISTS summary")

# REAL for floats
# In this table, sample isn't a primary key because each sample has multiple rows (long format data)
cursor.execute(
    """
    CREATE TABLE summary (
        sample TEXT,
        total_count INTEGER,
        population TEXT,
        count INTEGER,
        percentage REAL,
        FOREIGN KEY(sample) REFERENCES metadata(sample)
    )
"""
)

# we need to pivot the data from wide to long, so I'll go through the metadata row by row
# supposedly, wrapping it in "with connection" turns off autocommit
cursor.execute("SELECT sample, b_cell, cd8_t_cell, cd4_t_cell, nk_cell, monocyte FROM metadata")
insert_cursor = connection.cursor() # need a separate cursor for insertion or it'll interfere with the reading cursor


# To hit a balance between saving memory and keeping the number of insertions low, use batches.
batch = []
batch_size = 5000

with connection:
    print("Processing...")
    for row in cursor:
        sample = row[0]
        total_count = sum(row[1:]) # total cell count of sample

        # write a row for each cell type, so summary will have 5x the number of rows that metadata had
        for i in range(len(cell_types)):
            # sample and total_count were defined above
            population = cell_types[i]
            count = row[i+1] # cell_types population names started at index 0, cell counts started at index 1 in row
            percentage = count / total_count

            batch.append((sample, total_count, population, count, percentage))

        if len(batch) >= batch_size:
            insert_cursor.executemany("INSERT INTO summary (sample, total_count, population, count, percentage) VALUES (?, ?, ?, ?, ?)",
                                      batch)
            batch.clear()

    if batch: # if anything remaining, insert now
        insert_cursor.executemany("INSERT INTO summary (sample, total_count, population, count, percentage) VALUES (?, ?, ?, ?, ?)",
                                  batch)
        batch.clear()
print("Summary table has been written!")

# since the cell counts are now in the summary table, it's redundant to have them in the metadata table
for col in cell_types:
    query = f"ALTER TABLE metadata DROP COLUMN {col};"
    cursor.execute(query)

connection.commit()
connection.close()