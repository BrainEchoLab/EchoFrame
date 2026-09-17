function clean_empty_files(basePath)
% clean_empty_files - Removes any "recording_*" folder that does not contain valid data.
% Called by the acquisition-start scripts at exit (e.g. echoframe_acquisition_start.m).
%
% Syntax:
%   clean_empty_files(basePath)
%
% Inputs:
%   basePath - (Optional) The path that contains the recording folders.
%              If not provided, the current working directory is used.
%
% Description:
%   The function searches for all subfolders in basePath with names matching the pattern
%   'recording_YYYY-MM-DD_HHMMSS'. For each folder, it checks for the presence of the data files::
%
%       - bf_acq.dat
%       - pdi_acq.dat
%       - rf_acq.dat
%
%   For each found file, the function opens the file and reads the first 5 unsigned 64-bit
%   values (the header). It then examines the third header element (mBuffersDequeued). If any
%   file in the folder has mBuffersDequeued > 0, the folder is considered to contain valid data
%   and is preserved. If none of the files exist or if all the checked files have mBuffersDequeued
%   equal to 0, the folder is removed.
%
% Example:
%   % Put your own path here -- the folder that holds the recording_* folders.
%   clean_empty_files('C:\path\to\your\recordings')
%
% Date: 2025-02-10

if nargin < 1
    basePath = pwd;
end

% --- Step 1. Find all recording folders in basePath ---
folderList = dir(fullfile(basePath, 'recording_*'));
folderList = folderList([folderList.isdir]);

if isempty(folderList)
    fprintf('No "recording_*" folders found in %s.\n', basePath);
    return;
end

% --- Step 2. Define list of potential data files ---
fileNames = {'bf_acq', 'pdi_acq', 'rf_acq'};

% --- Step 3. Loop through each folder and check for valid data ---
for folderIndex = 1:numel(folderList)
    folderName = folderList(folderIndex).name;
    folderPath = fullfile(basePath, folderName);
    validDataFound = false;  % Flag to track if valid data is found in any file
    fileChecked = false;     % Flag to indicate at least one file was processed
    
    % Check each expected data file in the folder
    for k = 1:length(fileNames)
        currentName = fileNames{k};
        filePath = fullfile(folderPath, [currentName '.dat']);
        if exist(filePath, 'file') == 2
            fileChecked = true;
            fid = fopen(filePath, 'r');
            if fid == -1
                fprintf('Error opening file: %s\n', filePath);
                continue;
            end
            
            % Read 5 uint64 values from the file header.
            numHeaderElements = 5;
            header = fread(fid, numHeaderElements, '*uint64');
            fclose(fid);
            
            if numel(header) < numHeaderElements
                fprintf('Incomplete header in file: %s\n', filePath);
                continue;
            end
            
            % Check the third header element (mBuffersDequeued)
            mBuffersDequeued = header(3);
            
            if mBuffersDequeued > 0
                validDataFound = true;
                break;  % Valid data found; no need to check remaining files in this folder.
            end
        end
    end
    
    % --- Step 4. Remove the folder if no valid data was found ---
    if fileChecked && ~validDataFound
        % At least one data file was checked but none contained valid data.
        if local_remove_folder(folderPath)
            fprintf('Removed folder: %s\n', folderPath);
        end
    elseif ~fileChecked
        % None of the expected data files exist; consider the folder empty.
        if local_remove_folder(folderPath)
            fprintf('Removed folder (no data files found): %s\n', folderPath);
        end
    else
        fprintf('Folder %s contains valid data. No cleanup performed.\n', folderPath);
    end
end
end

% -------------------------------------------------------------------------

function ok = local_remove_folder(folderPath)
% Remove a folder tree, retrying briefly on failure and warning (not erroring)
% if it cannot be removed.
ok  = false;
msg = '';
for attempt = 1:3
    [ok, msg] = rmdir(folderPath, 's');
    if ok
        return;
    end
    pause(0.5);
end
warning('clean_empty_files:rmdir', ...
        ['Could not remove folder %s (%s). It may still be open (e.g. the MEX ', ...
         'was not destroyed, or the folder is open in another program); remove ', ...
         'it manually.'], folderPath, strtrim(msg));
end
