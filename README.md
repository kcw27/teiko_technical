# teiko_technical
Teiko Teiknical project.

Table of contents:
- [Instructions](#instructions)
- [Schema](#schema)
- [Code overview](#code-overview)
- [R Shiny dashboard images](#r-shiny-dashboard)
## Instructions
Please cd to the root directory of the repository before running any code.  

To install the conda environment:
```
make setup
```
make pipeline and make dashboard will run this automatically if it hasn't been run before, so this is only necessary if you want to run the scripts outside of either context.

To run the Nextflow pipeline (non-interactive analysis):
```
make pipeline
```
This saves the outputs to the nextflow_outputs/ dir. Refer to nextflow.config and the input/ dir for example input files. The defaults in nextflow.config run the analyses requested by the project assignment. Part 3 is found in the statistical_analysis_results/ subdir, and likewise for part 4 in the subset_analysis_results/ subdir.  
Since the assignment explicitly requested that the .db file be created in the repository root, I went against Nextflow best practices and copied the db (a potentially large file) to the repository root, as I wasn't sure whether a softlink would be accepted. The dblink/ subdir contains a softlink for this file, which is how I would normally do it.  
In case Nextflow gives you trouble, please check that the version installed is 26.04.0. Nextflow updates often break code that previously worked.
```
nextflow -v
```

To launch the dashboard (interactive analysis):
```
make dashboard
```
This first loads and summarizes the input data from the data/ dir in order to produce the database used by the dashboard, then launches the dashboard itself after printing the URL at which it can probably be found. (The IP address printed may or may not be correct. I have not tested this in GitHub Codespaces.) Example outputs may be found at gui_outputs/.

If for whatever reason you cannot see the URL in the console, please follow these instructions.
1. Get your IP address.
   ```bash
   hostname -I
   ```
2. Launch the GUI in the terminal.
   ```bash
   make dashboard
   ```  
3. Replace \<server-ip\> with your IP address, and open the link in a web browser. The GUI webpage will be ready when the terminal reads "Listening on http://0.0.0.0:3838". 
   ```text
   http://<server-ip>:3838
   ``` 

I am sure that it is possible to use a sentinel file to track whether the database has already been prepared (by either make pipeline or make dashboard) so as to avoid setting it up every time the pipeline is run or the dashboard is opened, but that has yet to be implemented. In the meantime, if you would like to avoid redundant database preparation, you may use this:
```
conda activate teiko-env
Rscript dashboard.R
```

## Schema
I set up the database with two tables: 
1. metadata: from the original cell-count.csv data. Final columns: project, subject, condition, age, sex, treatment, response, sample, sample_type	time_from_treatment_start
2. summary: summary data as described in part 2 of the assignment.
I kept these as separate tables because some analyses (like in part 4) only require the metadata table, and because if the information were saved as inner-joined instead of as two separate tables, there would be a lot of redundant data, since the populations from the same sample would have the same metadata.
I used 'sample' as the primary key in metadata, as it's unique to each row and can be used to link data from the two tables. It's not a primary key in summary because there are multiple rows per sample (one per cell population), but it can still be used to inner join the two tables as needed.  
After creating the summary table, I deleted the redundant cell count columns from metadata in order to save space.  
I think this schema scales well with study size, as it keeps the tables as small as possible. My code does require hard-coding the column names as opposed to automatically creating the columns upon importing a CSV, but I did it this way because I read that it isn't possible to turn a column into a primary key after it's already been created. 

## Code overview
### Part 1
load_data.py creates the database from scratch so that it can be run multiple times with no ill effect. It initializes the metadata table and then loads the input data (cell-count.csv) in chunks. While not strictly necessary for this particular dataset, this keeps the memory usage low in case the input data is large. Since this script must run without arguments, I hard-coded the database path.  
It's possible to write this script to always save the database to the repository root regardless of where it's run from, but because I used Nextflow for the pipeline, I opted to have it save to the current directory instead.  

### Part 2
summarize_data.py adds the summary table to the database from part 1. Essentially, I pivoted the cell count data from wide to long when writing to the summary table. I iterated over the rows of the metadata table and calculated the other information per row. There may be a more efficient way to handle this part, but I tried to at least limit the number of times that the data had to be inserted into the summary table by collecting it in batches. Processing in batches also keeps the memory requirement low.  
The instructions were ambiguous as to whether this part should save a summary table as a CSV file. I opted to just keep it as a table in the database because if this were a large database, the resulting file would be large. In any case, the summary table may be viewed on the landing page of the dashboard.

### Part 3
statistical_analysis.R takes either a filtered dataset or the filtering instructions as a two-column CSV table, and runs analyses that compare numeric variables between responders and non-responders. For this reason, it's recommended to not use response as a filtering criterion when running these functions.  
The boxplots are exported as PDF because my lab prefers vector over raster formats for images that might be used for publication. The Q-Q plots (discussed later) are for the user's own reference, so I just exported them as PNGs so you can quickly glance at the thumbnails.
To compare the distribution of a numeric variable (in this case, cell population frequency) between groups, one can use either a parametric test such as a t-test or a non-parametric test such as a Mann-Whitney U test. Parametric tests are more powerful, but they come with assumptions, namely that every group's data is normal. You can invoke the Central Limit Theorem to ignore normality and run the t-test anyway, but it's a good idea to check the normality of the data first. Similar to what I did for a dashboard I previously built, I allowed the user to first check the normality of the data using the Shapiro-Wilk test and Q-Q plots. The dashboard returns a suggestion for whether to use a parametric or non-parametric test, but it's up to the user's judgment. 
The assignment focused on cell population frequency so I hard-coded that as the numeric variable for the box plots and statistical tests, but if I were to redo this, I would allow the user to choose between percentage and count (numeric columns from the summary table which differ between populations). I would add drop-down menus to the statistical analysis tab in the dashboard to allow the user to choose between these two variables.   

### Part 4
subset_data.R also takes a filtered dataset or filtering instructions, but the user must additionally supply a categorical grouping variable. The script accesses the metadata table and counts the number of observations that occur in each level of the grouping variable.

### Nextflow pipeline
I used nextflow.config to provide input files for the specific analyses that the assignment required. It is possible to instead provide them as part of a params file, but I wanted to treat this as a tutorial run of sorts, and didn't want to have to call it with the params file each time.  
I set it up so that the user can run as many analyses on the same dataset in a single run as they would like, rather than limiting it to one set of input files per run. The input files (filtering_criteria.csv and grouping_variable.txt) should end with an empty line or else R will complain that the files are malformed. Even if R issues that warning, though, it seems to process the data just fine.

### R Shiny dashboard
The dashboard has three tabs, which represent parts 2, 3, and 4 respectively. Here are some development notes.
* For the sake of simplicity (at some cost to flexibility), all filtering statements are phrased as "variable == value" and joined together with "AND". I considered implementing the ability to filter by numeric range for the age column.
* I avoided loading the entire database into memory. Parts of the tables are joined and pulled into memory only as necessary, e.g. to display the next 100 rows or to filter the df for analysis/download. It displays how many rows the table has at any given state of filtering so that the user gets a sense of whether their request is reasonable or not. Nothing will prevent the user from downloading the entire joined table as a CSV, but if the user sees that it has a large number of rows, that kind of behavior will be discouraged.  
* The filtering menu allows the user to freely add, remove, and reset filtering steps. I drew inspiration from a dashboard I had previously developed- I only allowed the user to add filtering steps and to completely reset them, so it was an annoyance whenever I made a mistake and only needed to undo one filtering step.  
* Whenever the user saves the filtered data or runs analyses on it, a log file is produced which records the filtering that was performed. The aforementioned dashboard from a previous project inspired this one too- I had implemented the ability to save filtered data, but because I didn't keep a record of how the data was filtered, it was difficult to reuse the files down the line.
* After analyses are run, the results are displayed in the dashboard. This was also borrowed from a dashboard I previously developed.
* To facilitate opening the dashboard in a web browser, R prints the (probable) URL to the terminal. I cannot guarantee that this URL will work 100% of the time, but it has worked when I've tested it.

#### Dashboard images
##### Tab 1: data overview
<img width="2496" height="1476" alt="image" src="https://github.com/user-attachments/assets/a98ebdb0-a7e9-4347-a521-0bf7339e7caa" />
<img width="2496" height="1459" alt="image" src="https://github.com/user-attachments/assets/07dc3ec6-44cb-41dc-805c-6574c948ecc7" />

##### Tab 2: statistical analysis
Once again: I wish I had implemented the ability to choose between numeric variables from a dropdown window, but it should be easy enough to add that feature.
<img width="2496" height="1462" alt="image" src="https://github.com/user-attachments/assets/f88d6448-9651-4a1b-aa51-26c252f48926" />
<img width="2496" height="2769" alt="image" src="https://github.com/user-attachments/assets/1a884dd9-b091-401b-a1ef-5a4c0e01b07b" />
<img width="2492" height="1462" alt="image" src="https://github.com/user-attachments/assets/0ba43db0-f0ed-4443-bd1f-d98a45d79dc7" />

##### Tab 3: subset analysis
<img width="2496" height="658" alt="image" src="https://github.com/user-attachments/assets/11c9502c-5641-4839-9574-6c6125341350" />



