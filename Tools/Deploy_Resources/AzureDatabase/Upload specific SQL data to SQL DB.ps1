
Name: Upload SQL data from Azure Storage to Azure DB
Action: Execute Script in Virtual Machine
Event: First Displayable
Blocking: 	
Delay: 70 Seconds
Timeout: 10 Minutes
Retries: 4
Error Action: End Lab
Enabled	



# Parameters
$GitHubSqlUrl = "https://raw.githubusercontent.com/greg-ray-lods/45-404-13/refs/heads/main/InsertData.sql"  # GitHub URL to the .sql file
$LocalSqlFilePath = "C:\Users\@lab.VirtualMachine(Workstation1).Username\Downloads\InsertData.sql"            # Local path to save the .sql file

# Sql Content
$SqlContent = @'
USE DB01;

-- Begin Transaction
BEGIN TRY
    BEGIN TRANSACTION;

    -- Create Products table if it doesn't exist
    IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Products' AND schema_id = SCHEMA_ID('dbo'))
    BEGIN
        CREATE TABLE dbo.Products (
            ProductID INT IDENTITY(1,1) PRIMARY KEY,
            ProductName NVARCHAR(100),
            Price DECIMAL(10, 2),
            Description NVARCHAR(255),
            CategoryID INT
        );
        PRINT 'Products table created successfully.';
    END
    ELSE
    BEGIN
        PRINT 'Products table already exists.';
    END;

    -- Insert data into the Products table
    INSERT INTO dbo.Products (ProductName, Price, Description, CategoryID)
    VALUES
        -- Fruits
        ('Organic Blueberries', 4.99, 'Sweet, antioxidant-rich organic blueberries.', 1),
        ('Bananas', 1.29, 'Organic bananas, naturally ripened.', 1),
        ('Organic Avocados', 2.99, 'Rich, creamy organic avocados.', 1),

        -- Vegetables
        ('Organic Broccoli', 3.49, 'Fresh, crisp organic broccoli.', 2),
        ('Organic Carrots', 2.49, 'Sweet and crunchy organic carrots.', 2),
        ('Organic Kale', 3.99, 'Dark, leafy green packed with nutrients.', 2),

        -- Dairy
        ('Organic Greek Yogurt', 6.99, 'Thick, creamy organic Greek yogurt.', 3),
        ('Organic Cheddar Cheese', 5.49, 'Sharp and rich organic cheddar cheese.', 3),
        ('Free-Range Eggs', 4.29, 'Fresh, free-range large brown eggs.', 3),

        -- Bakery
        ('Gluten-Free Bread', 6.99, 'Soft, gluten-free sandwich bread.', 4),
        ('Sourdough Loaf', 4.99, 'Freshly baked artisan sourdough bread.', 4),
        ('Vegan Chocolate Chip Cookies', 5.99, 'Delicious vegan chocolate chip cookies.', 4),

        -- Meat & Seafood
        ('Grass-Fed Ground Beef', 8.99, '100% grass-fed ground beef.', 5),
        ('Organic Chicken Breast', 9.99, 'Organic, free-range chicken breast.', 5),
        ('Wild-Caught Shrimp', 13.99, 'Fresh, wild-caught shrimp from the Gulf.', 5),

        -- Pantry Staples
        ('Organic Olive Oil', 10.99, 'Extra virgin olive oil from Italy.', 6),
        ('Brown Rice', 2.99, 'Nutty and wholesome organic brown rice.', 6),
        ('Organic Almond Butter', 9.99, 'Smooth organic almond butter with no added sugar.', 6),

        -- Additional entries
        ('Organic Gala Apples', 3.99, 'Crisp and sweet, perfect for snacking.', 1),
        ('Organic Baby Spinach', 4.99, 'Fresh organic spinach, ready to use.', 2),
        ('Almond Milk - Unsweetened', 2.99, 'Dairy-free milk alternative, unsweetened.', 3),
        ('Whole Wheat Bread', 5.49, 'Freshly baked whole wheat bread.', 4),
        ('Wild-Caught Salmon', 12.99, 'Fresh wild-caught Alaskan salmon.', 5),
        ('Organic Quinoa', 6.99, 'A versatile grain, rich in protein.', 6);

    -- Commit Transaction
    COMMIT TRANSACTION;
    PRINT 'Data inserted successfully into Products table.';

    -- Verify insertion
    DECLARE @InsertedRows INT;
    SELECT @InsertedRows = COUNT(*) FROM dbo.Products;
    PRINT 'Total rows in Products table: ' + CAST(@InsertedRows AS NVARCHAR(10));

END TRY
BEGIN CATCH
    -- Rollback if an error occurs
    ROLLBACK TRANSACTION;
    PRINT 'Error occurred. Transaction rolled back.';
    PRINT ERROR_MESSAGE();
END CATCH;
'@

# Azure SQL Parameters
$resourceGroupName = "RG1"
$serverName = "sql@lab.LabInstance.Id"
$databaseName = "DB01"
$sqladminLogin = "azureadmin"
$sqladminPassword = "QWERTqwert12345"  # Plain text password

# Step 1: Download the .sql file from GitHub
# try {
#     Invoke-WebRequest -Uri $GitHubSqlUrl -OutFile $LocalSqlFilePath -ErrorAction Stop
#     Write-Output "Downloaded SQL script successfully to $LocalSqlFilePath."
# } catch {
#     Write-Output "Failed to download SQL script from GitHub: $_"
#     Write-Output "Error details: $($Error[0])"
#     exit
# }
# Alternative
$SqlContent | Out-File -FilePath $LocalSqlFilePath


# Step 2: Define SQL connection and execute commands
$connectionString = "Server=tcp:$serverName.database.windows.net,1433;Initial Catalog=$databaseName;User ID=$sqladminLogin;Password=$sqladminPassword;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;"

try {
    # Load the SQL script into a variable
    $sqlQuery = Get-Content -Path $LocalSqlFilePath -Raw
    Write-Output "Loaded SQL script content successfully."

    # Create SQL Connection and Command
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $connectionString
    $connection.Open()

    $command = $connection.CreateCommand()
    $command.CommandText = $sqlQuery
    $command.ExecuteNonQuery()

    Write-Output "SQL script executed successfully."
} catch {
    Write-Output "Failed to execute SQL script: $_"
    Write-Output "Error details: $($Error[0])"
} finally {
    # Clean up the connection and the local .sql file
    if ($connection.State -eq [System.Data.ConnectionState]::Open) {
        $connection.Close()
    }
    if (Test-Path -Path $LocalSqlFilePath) {
        Remove-Item -Path $LocalSqlFilePath -Force
        Write-Output "Local SQL script file removed from $LocalSqlFilePath."
    }
}
