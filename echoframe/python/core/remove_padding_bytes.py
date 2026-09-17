import numpy as np
import os
import sys

def clean_file(original_filepath, clean_filepath):
    # Open files for reading and writing in little-endian format
    with open(original_filepath, 'rb') as fileID_original, open(clean_filepath, 'wb') as fileID_clean:
        # Read the header fields; field[1] is the header size in bytes.
        header_fields = np.fromfile(fileID_original, dtype=np.uint64, count=6)
        mVersion            = int(header_fields[0])
        mHeaderSize         = int(header_fields[1])
        mBuffersDequeued    = int(header_fields[2])
        effectiveBufferSize = int(header_fields[3])
        mPaddingBytes       = int(header_fields[4])

        # Copy the header verbatim (exactly mHeaderSize bytes), zeroing only
        # the padding field since the cleaned file has none.
        fileID_original.seek(0)
        header_bytes = bytearray(fileID_original.read(mHeaderSize))
        np.frombuffer(header_bytes, dtype=np.uint64)[4] = np.uint64(0)
        fileID_clean.write(header_bytes)

        # Position both files at the end of the header before copying data.
        fileID_original.seek(mHeaderSize)
        fileID_clean.seek(mHeaderSize)

        # Copy data without padding bytes
        for bufferIdx in range(mBuffersDequeued):

            # Read the actual data from the buffer (2 * effectiveBufferSize as 'float32' for complex data)
            data_chunk_raw = np.fromfile(fileID_original, dtype=np.float32, count=2 * int(effectiveBufferSize))

            # Check if the data read was less than expected (EOF check)
            data_chunk_size = len(data_chunk_raw)
            if data_chunk_size < 2 * effectiveBufferSize:
                print(f'Warning: Incomplete data in buffer {bufferIdx + 1}. Read {data_chunk_size} elements instead of {2 * effectiveBufferSize}.')
                if data_chunk_size == 0:
                    break  # Exit if no data was read

            # Write the data that was read to the new file (without padding)
            data_chunk_raw.tofile(fileID_clean)

            # Skip padding bytes in the original file
            fileID_original.seek(mPaddingBytes, 1)

    # Check final cleaned file size
    clean_file_size = os.path.getsize(clean_filepath)
    print(f'Final cleaned file size: {clean_file_size} bytes')
    print(f'File copied without padding bytes to {clean_filepath}')

def main():
    # Placeholder paths -- put your own here, or pass them on the command line:
    #   python remove_padding_bytes.py <original.dat> <cleaned.dat>
    default_original_path = r'C:\path\to\your\recording\bf_acq.dat'
    default_clean_path = r'C:\path\to\your\recording\bf_acq_cleaned.dat'

    # Check if arguments are passed; otherwise, use defaults
    if len(sys.argv) < 3:
        original_filepath = default_original_path
        clean_filepath = default_clean_path
        print('No paths provided. Falling back to the placeholder paths in main() -- '
              'edit them, or pass both paths as arguments.')
        print(f'Original: {original_filepath}')
        print(f'Cleaned:  {clean_filepath}')
    else:
        # Parse arguments
        original_filepath = sys.argv[1]
        clean_filepath = sys.argv[2]

    # Call the function to clean the file
    clean_file(original_filepath, clean_filepath)

# This allows the script to be run independently or imported as a module
if __name__ == "__main__":
    main()
