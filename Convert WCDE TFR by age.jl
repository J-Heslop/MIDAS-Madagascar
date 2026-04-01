
# ConvertsWCDE survival rate into mortality

using CSV, DataFrames

# directories

    data_path = "C:\\Users\\Jack\\OneDrive - University of East Anglia\\ISF - Migration modelling consultancy\\Datasets\\SSP demography\\wcde_data-age specific fertility rate.csv"
    output_dir = "C:\\Users\\Jack\\OneDrive - University of East Anglia\\Documents\\GitHub\\MIDAS-Madagascar\\Data\\"

# Load data 

    tfr_df = CSV.read(data_path,DataFrame;header=9)

# Variables 

    ages = unique(tfr_df.Age)
    ssps = ["SSP2","SSP5"]
    epochs = unique(demog_df.Period)
    #max_ages = [0,4,9,14,19,24,29,34,39,44,,49,54,59,64,69,74,79,84,100]

# Output dataframes

    output_df = DataFrame(
        "scenario" => Vector{String}(undef,length(ages)),
        "age" => ages
    )

    for period in epochs
        output_df[!,"$period"] .= 0.0

    end 

# Main 

    for ssp in ssps # ssp = "SSP2"
        ssp_output_df = copy(output_df)
        ssp_output_df.scenario .= ssp
        ssp_input_df = tfr_df[findall(tfr_df.Scenario .== ssp),:]
        for epoch in epochs # epoch = "2020-2025"
        
            epoch_df = ssp_input_df[findall(ssp_input_df.Period.==epoch),:]
            ssp_output_df[indexin(epoch_df.Age,ages),epoch] = epoch_df[:,:Rate]
            
        end 

        CSV.write(string(output_dir,"MDG $ssp TFR.csv"),ssp_output_df)

    end 


    


 

