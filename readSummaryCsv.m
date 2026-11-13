function T = readSummaryCsv(f)
% READSUMMARYCSV  Read an analysis summary CSV without trusting auto-detection.
%
%   T = readSummaryCsv(fullfile(runDir, 'fi_drivers_summary.csv'))
%
% WHY THIS EXISTS
% readtable(f) returned a 271x6 table of Var1..Var6 from a file that is 327 kB
% and carries a correct 95-column header. The cause is delimiter detection: the
% first data field is a run filename such as
%
%     MC_Run_T001_12_2026-09-07_slim.mat
%
% which splits on UNDERSCORE into exactly six fields -- MC, Run, T001, 12,
% 2026-09-07, slim.mat. Auto-detection preferred that to the comma, so every
% column of every summary read back through the cache was wrong, and the two
% scripts that consume these files reported the parameters as missing rather
% than as misparsed.
%
% Nothing was wrong with the written files. The failure was entirely in the
% read, which is why it only ever showed up on the cached path: fi_drivers with
% 'Refresh',true builds the table in memory and never goes through readtable.
%
% WHAT THIS DOES DIFFERENTLY
% 1. Names the delimiter instead of letting MATLAB infer it.
% 2. Counts the columns in the file's own header line and CHECKS the parsed
%    width against it. A misparse then errors instead of returning a plausible
%    but wrong table -- which is the failure mode that cost the afternoon.
% 3. Falls back to an explicit textscan if the check fails, so a future
%    detection quirk degrades to slow-but-correct rather than to blocked.
%
% Comma-quoting is handled (%q), so a quoted field containing a comma survives.

if ~exist(f, 'file')
    error('readSummaryCsv:missing', 'File does not exist: %s', f);
end

% ------------------------------------------------- the file's own header line
fid = fopen(f, 'r');
if fid < 0
    error('readSummaryCsv:cannotOpen', 'Could not open %s', f);
end
hdr = fgetl(fid);
fclose(fid);
if ~ischar(hdr) || isempty(hdr)
    error('readSummaryCsv:emptyHeader', 'No header line in %s', f);
end
hdr = regexprep(hdr, '^\xEF\xBB\xBF', '');          % strip a UTF-8 BOM if present
hdrNames = strtrim(strsplit(hdr, ','));
nExpect  = numel(hdrNames);

% ------------------------------------------------------------- preferred path
T = table.empty;
try
    T = readtable(f, 'Delimiter', ',', 'ReadVariableNames', true, ...
                     'VariableNamingRule', 'preserve');
catch err
    warning('readSummaryCsv:readtableFailed', ...
            'readtable failed on %s (%s) -- falling back to textscan.', f, err.message);
end

if ~isempty(T) && width(T) == nExpect
    return;
end

% ------------------------------------------------------------- fallback parse
% Reached only if the explicit delimiter still did not reproduce the header
% width. Read every field as text, then convert the columns that are wholly
% numeric. Do NOT coerce a column that fails to parse -- silently turning a
% malformed value into NaN is how a bad run hides inside an ensemble.
if ~isempty(T)
    warning('readSummaryCsv:widthMismatch', ...
            ['readtable returned %d columns but the header of %s declares %d. ' ...
             'Re-parsing explicitly.'], width(T), f, nExpect);
end

fid = fopen(f, 'r');
fgetl(fid);                                          % discard header
C = textscan(fid, repmat('%q', 1, nExpect), ...
             'Delimiter', ',', 'EndOfLine', '\r\n', 'CollectOutput', false);
fclose(fid);

nRow = numel(C{1});
T = table();
for k = 1:nExpect
    col = C{k};
    if numel(col) ~= nRow
        error('readSummaryCsv:ragged', ...
              ['Column %d ("%s") of %s has %d values against %d in column 1. ' ...
               'The file is ragged -- rebuild it rather than reading it.'], ...
              k, hdrNames{k}, f, numel(col), nRow);
    end
    num = str2double(col);
    % A column is numeric only if EVERY non-empty entry parsed. Empty cells are
    % genuine missing values and become NaN; unparseable text means the column
    % is text and is kept as text.
    nonEmpty = ~cellfun(@isempty, strtrim(col));
    if any(nonEmpty) && all(~isnan(num(nonEmpty)))
        T.(matlab.lang.makeValidName(hdrNames{k})) = num;
    else
        T.(matlab.lang.makeValidName(hdrNames{k})) = col;
    end
end
% Preserve the header spellings exactly; makeValidName above only guards the
% assignment, and the consumers match on substrings of the original names.
% These headers are already valid identifiers, so this normally does nothing --
% but a duplicated or non-identifier header would error here, and keeping the
% sanitised names is better than refusing to return the table at all.
try
    T.Properties.VariableNames = hdrNames;
catch err
    warning('readSummaryCsv:keptSanitisedNames', ...
            ['Could not restore the header spellings of %s (%s). Using the ' ...
             'sanitised names; substring matching still works.'], f, err.message);
end

if width(T) ~= nExpect
    error('readSummaryCsv:fallbackFailed', ...
          'Fallback parse of %s gave %d columns, not %d.', f, width(T), nExpect);
end
fprintf('readSummaryCsv: fallback parse of %s -> %d rows x %d cols.\n', ...
        f, height(T), width(T));
end
