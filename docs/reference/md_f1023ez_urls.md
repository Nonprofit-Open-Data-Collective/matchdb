<div id="main" class="col-md-9" role="main">

# The 1023-EZ approval URLs are not consistently named

<div class="ref-description section level2">

`md_source_urls()` renders one pattern, which is wrong for this source
often enough to matter. The IRS has published these files under at least
three conventions:

</div>

<div class="section level2">

## Details

<div class="sourceCode">

      f1023ez_approvals_2014.xlsx     underscores, lowercase   2014-2016, 2018-2019
      f1023EZ_approvals_2017.xlsx     underscores, EZ upper    2017
      f1023ez-approvals-2020.xlsx     hyphens                  2020-2023

</div>

2024 is listed on the approvals page under `/system/files/irs-tege/` and
**404s**, so the published range is 2014-2023 whatever the page implies.

The downloader therefore tries each convention rather than trusting one.
This is recorded because a single-pattern fetch would silently acquire
nine years and look complete.

Column names shift too: the EIN header is `EIN` through 2018 and `Ein`
by 2023, which is why `md_xlsx_to_csv()` matches case-insensitively.

</div>

</div>
