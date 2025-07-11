# Loading required modules
import os
import re
import time
import json
import random
import uuid
import numpy as np
from flask import Flask, render_template, jsonify, request, g, current_app, session
from flask_cors import CORS
from dotenv import load_dotenv
from openai import OpenAI
import vertexai
from vertexai.generative_models import GenerativeModel, Part, Content
from ddtrace.llmobs import LLMObs
from ddtrace.llmobs.decorators import llm, workflow, task, agent, tool, retrieval
from ddtrace.llmobs.utils import Prompt
from logger import setup_logger
from config import Config
from functools import wraps
from datetime import datetime, timedelta
import html

# Setup logger
logger = setup_logger('llm-agent-logger')

# Rate limiting configuration
RATE_LIMIT_WINDOW = 60  # 1 minute window
RATE_LIMIT_MAX_REQUESTS = 30  # Maximum requests per window
request_history = {}

def rate_limit(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        client_ip = request.remote_addr
        current_time = datetime.now()
        
        # Clean up old requests
        if client_ip in request_history:
            request_history[client_ip] = [t for t in request_history[client_ip] 
                                        if current_time - t < timedelta(seconds=RATE_LIMIT_WINDOW)]
        
        # Check rate limit
        if client_ip in request_history and len(request_history[client_ip]) >= RATE_LIMIT_MAX_REQUESTS:
            logger.warning(f"Rate limit exceeded for IP: {client_ip}")
            return jsonify({
                "error": "Rate limit exceeded. Please try again later.",
                "retry_after": RATE_LIMIT_WINDOW
            }), 429
        
        # Add current request to history
        if client_ip not in request_history:
            request_history[client_ip] = []
        request_history[client_ip].append(current_time)
        
        return f(*args, **kwargs)
    return decorated_function

# Custom exception classes for better error tracking
class SwagBotError(Exception):
    """Base exception class for SwagBot"""
    def __init__(self, message, status_code=500):
        self.message = message
        self.status_code = status_code
        super().__init__(self.message)

class LLMError(SwagBotError):
    """Exception raised for LLM-related errors"""
    def __init__(self, message, status_code=500):
        super().__init__(f"LLM Error: {message}", status_code)

class ValidationError(SwagBotError):
    """Exception raised for validation errors"""
    def __init__(self, message, status_code=400):
        super().__init__(f"Validation Error: {message}", status_code)

class ConfigurationError(SwagBotError):
    """Exception raised for configuration errors"""
    def __init__(self, message, status_code=500):
        super().__init__(f"Configuration Error: {message}", status_code)

# Set global variables
ml_app = "swagbot"
app_version="0.5"
chat_history = []
LLM_TYPE, MODEL_ID = Config.LLM_TYPE, Config.MODEL_ID
CURRENT_MODEL_ID = MODEL_ID
logo_path = 'static/images/default-chatbot-logo.jpg'
welcome_message = f"Hey there! I'm SwagBot powered by {LLM_TYPE} and here to help you with questions related to Swagstore. Just write to me when ready!"

# Initialize Flask app
app = Flask(__name__)
CORS(app)

def initialize_llm():
    """Initialize the appropriate LLM based on configuration"""
    try:
        sys_prompt = open(f'{Config.MODEL_SYS_INSTRUCTIONS}', 'r').read()
        if LLM_TYPE == "OPEN_AI":
            logo_path = 'static/images/openai-logo.png'
            logger.info(f"Initializing {LLM_TYPE}, model: {MODEL_ID}")
            client = OpenAI(api_key=Config.OPENAI_API_KEY)
            chat_history = [({"role": "assistant", "content": welcome_message})]
            return client, sys_prompt, chat_history, logo_path

        elif LLM_TYPE == "GEMINI":
            logo_path = 'static/images/google-logo.png'
            logger.info(f"Initializing {LLM_TYPE} - VertexAi in {Config.GCP_PROJECT_ID}, location: {Config.GCP_LLM_LOCATION}")
            vertexai.init(project=Config.GCP_PROJECT_ID, location=Config.GCP_LLM_LOCATION)
            chat_history = [(Content(role="model", parts=[Part.from_text(welcome_message)]))]
            return None, sys_prompt, chat_history, logo_path

        else:
            raise ValueError(f"Invalid LLM_TYPE: {LLM_TYPE}")
    except Exception as e:
        logger.error(f"Failed to initialize LLM: {str(e)}", exc_info=True)
        raise

# Initialize LLM
try:
    client, sys_prompt, chat_history, logo_path = initialize_llm()
    logger.info(f"Loaded Systems Instructions:\n{sys_prompt}")
except Exception as e:
    logger.error(f"Error during startup: {str(e)}")
    raise

# Homepage route
@app.route('/')
def index():
    global chat_history, logger
    # Add UUID to header for each session
    gen_uuid = uuid.uuid4()
    session['uuid'] = str(gen_uuid)
    logger.info(f"Using ID: {gen_uuid}")
    if LLM_TYPE == "OPEN_AI":
        chat_history = [({"role": "assistant", "content": welcome_message})] 
    elif LLM_TYPE == "GEMINI":
        chat_history = [(Content(role="model", parts=[Part.from_text(welcome_message)]))]

    logger.info(f"Chat history initialized for {LLM_TYPE}:\n {chat_history}")
    return render_template('index.html', 
        logo_path=logo_path, 
        llm_type=LLM_TYPE, 
        bot_name="SwagBot", 
        store_name="Swagstore", 
        welcome_message=welcome_message,
        dd_application_id=Config.DD_APPLICATION_ID,
        dd_client_token=Config.DD_CLIENT_TOKEN,
        dd_site=Config.DD_SITE,
        dd_env=Config.DD_ENV
    )

# Input validation and sanitization
def sanitize_input(text):
    """Sanitize user input to prevent XSS and injection attacks"""
    if not isinstance(text, str):
        return str(text)
    # Remove any HTML tags
    text = re.sub(r'<[^>]+>', '', text)
    # Escape HTML special characters
    text = html.escape(text)
    # Remove any control characters
    text = ''.join(char for char in text if ord(char) >= 32)
    return text.strip()

def validate_user_request(request_data):
    """Validate user request data"""
    if not isinstance(request_data, str):
        raise ValidationError("Request data must be a string")
    
    # Check length limits
    if len(request_data) > 1000:  # Maximum 1000 characters
        raise ValidationError("Request data exceeds maximum length of 1000 characters")
    
    # Check for potentially harmful patterns
    harmful_patterns = [
        r'<script.*?>',  # Script tags
        r'javascript:',  # JavaScript protocol
        r'on\w+\s*=',    # Event handlers
        r'data:',        # Data URLs
        r'vbscript:',    # VBScript protocol
    ]
    
    for pattern in harmful_patterns:
        if re.search(pattern, request_data, re.IGNORECASE):
            raise ValidationError("Request contains potentially harmful content")
    
    return sanitize_input(request_data)

# API route for handling chatbot requests
@app.route('/data', methods=['POST'])
@rate_limit
def get_data():
    global logger
    request_id = str(uuid.uuid4())
    logger.info(f'[Request ID: {request_id}] Handling request to /data')
    
    try:
        if not request.is_json:
            return jsonify({"error": "Request must be JSON"}), 400
            
        request_json = request.get_json()
        if not request_json or 'data' not in request_json:
            return jsonify({"error": "Missing 'data' in request body"}), 400
            
        user_request = request_json.get('data')
        logger.info(f'[Request ID: {request_id}] Processing user request: {user_request}')
        
        processed_response = process_agent_request(request)
        logger.info(f'[Request ID: {request_id}] Successfully processed request')
        
        return jsonify({
            "message": processed_response,
            "request_id": request_id
        }), 200
    
    except Exception as e:
        logger.error(f'[Request ID: {request_id}] Error: {str(e)}', exc_info=True)
        return jsonify({
            "error": str(e),
            "request_id": request_id
        }), 500

@agent(name=ml_app)
def process_agent_request(request):
    global model, chat_history
    try:
        request_json = request.get_json()
        if not request_json or 'data' not in request_json:
            logger.error('Invalid request: Missing "data" in request body', exc_info=True)
            return jsonify({"error": "Bad Request - Missing \'data\' in request body"}), 400

        user_request = request_json.get('data')
        LLMObs.annotate(input_data=user_request)
        categorized_llm_answer = categorize_user_request(user_request)
        logger.info(f"Categorized LLM Answer: {categorized_llm_answer}")
        metrics = categorized_llm_answer['metrics']
        categorized_llm_answer.pop('metrics', None)

        logger.info(f"Processing categorized user request for category: {categorized_llm_answer}")

        # Route the response based on the category
        category_to_function = {
            "Product-Information": process_product_information_request,
            "Promotion": process_promotion_request,
            "Help-Customer-Service": process_help_cs_request,
            "Feedback": process_feedback_request,
        }
        response_function = category_to_function.get(categorized_llm_answer['category'], lambda x: categorized_llm_answer)
        
        processed_response = response_function(categorized_llm_answer)
        
        if 'metrics' in processed_response.keys():
            logger.info(f"Summing metrics: {metrics} + {processed_response['metrics']}")
            metrics = {key: metrics[key] + processed_response['metrics'][key] for key in metrics}

        logger.info(f"Annotating Data: {user_request}, {processed_response['sys_instructions']}")
        LLMObs.annotate(
            metrics=metrics,
            prompt=Prompt(
                variables={"user_request": user_request, "sys_instructions": processed_response['sys_instructions']},
                rag_query_variables=["user_request"],
                rag_context_variables=["sys_instructions"]
            )
        )
            
        return processed_response['response']

    except Exception as e:
        if LLM_TYPE == "GEMINI":
            model = GenerativeModel(MODEL_ID, system_instruction=sys_prompt)
        raise

# Function to categorize user requests
@workflow(name="categorize_user_request")
def categorize_user_request(user_request) -> dict:
    global model

    # Use CATEGORIZATION_MODEL_ID if set, otherwise use default model
    model_id = Config.CATEGORIZATION_MODEL_ID if Config.CATEGORIZATION_MODEL_ID else MODEL_ID
    raw_llm_answer = call_llm(user_request, model_id=model_id)

    # Randomly introduce delay and error (10% chance)
    if random.random() < 0.1:
        time.sleep(5)
        raise Exception("Failed categorizing the user request")

    categorized_llm_answer = parse_llm_response(raw_llm_answer['response'])
    categorized_llm_answer['user_request'] = user_request
    categorized_llm_answer['metrics'] = raw_llm_answer['metrics']
    categorized_llm_answer['sys_instructions'] = raw_llm_answer['sys_instructions']

    return categorized_llm_answer


@tool(name="call_llm")
def call_llm(user_request, sys_instructions=None, model_id=MODEL_ID):
    global CURRENT_MODEL_ID
    CURRENT_MODEL_ID = model_id
    if LLM_TYPE == "GEMINI":
        return call_gemini(user_request, sys_instructions, model_id)
    elif LLM_TYPE == "OPEN_AI":
        return call_openai(user_request, sys_instructions, model_id)
    else:
        logger.error(f"Unsupported LLM type: {LLM_TYPE}", exc_info=True)
        raise Exception(f"Unsupported LLM type: {LLM_TYPE}")

def log_system_instructions(system_instructions, model_type, model_id):
    """Helper function to log system instructions consistently"""
    logger.info(f"System Instructions for {model_type} ({model_id}): {system_instructions}")

def handle_llm_error(error, request_data, model_type):
    """Helper function to handle LLM errors consistently"""
    logger.error(f"Error in {model_type} with input: {request_data}: {str(error)}", exc_info=True)
    raise LLMError(f"{model_type} error: {str(error)}")

# Function to call the Gemini model (Vertex AI)
def call_gemini(user_request, additional_sys_prompt=None, model_id=None):
    global model, sys_prompt, chat_history
    
    try:        
        if additional_sys_prompt:
            system_instructions = sys_prompt + "\n" + additional_sys_prompt
        else:
            system_instructions = sys_prompt
        
        logger.info(f'Calling Gemini model: {model_id}')
        
        log_system_instructions(system_instructions, "Gemini", model_id)
        
        # This will append to global chat_history
        chat = GenerativeModel(model_id, system_instruction=system_instructions).start_chat(history=chat_history)
        with LLMObs.annotation_context(
           prompt = Prompt(
               variables = {
                    "user_request": user_request,
                    "sys_instructions": system_instructions
                },
                rag_query_variables=["user_request"],
                rag_context_variables=["sys_instructions"]
            )
        ): response = chat.send_message(user_request)

        logger.info(f"Received response from Gemini: {response}")
        generated_text = response.text
        metrics = {
            "input_tokens": response.usage_metadata.prompt_token_count,
            "output_tokens": response.usage_metadata.candidates_token_count,
            "total_tokens": response.usage_metadata.total_token_count
        }
        
        span_context = LLMObs.export_span(span=None)
        confidence_score = np.exp(response.candidates[0].avg_logprobs)
        logger.info(f"Submitting evaluation for Gemini response: {confidence_score}")
        LLMObs.submit_evaluation(
            span_context,
            label="confidence",
            metric_type="score",
            value=float(confidence_score),
            ml_app=ml_app
        )
        return {'response': generated_text, 'sys_instructions': system_instructions, 'metrics': metrics}
    except Exception as e:
        handle_llm_error(e, user_request, "Gemini")

# Function to call the OpenAI model
def call_openai(user_request, additional_sys_prompt=None, model_id=None):
    global messages, sys_prompt, chat_history
    logger.info('Calling OpenAI model')

    try:
        if additional_sys_prompt:
            system_instructions = sys_prompt + "\n" + additional_sys_prompt
        else:
            system_instructions = sys_prompt
        
        log_system_instructions(system_instructions, "OpenAI", model_id)
        
        # Add system prompt and user request to the message history
        messages = [{"role": "system", "content": system_instructions}]
        messages.extend(chat_history)
        messages.append({"role": "user", "content": user_request})
        
        logger.info(f"Calling OpenAI with history: {chat_history} + {user_request}")
        
        with LLMObs.annotation_context(
           prompt = Prompt(
               variables = {
                    "user_request": user_request,
                    "sys_instructions": system_instructions
                },
                rag_query_variables=["user_request"],
                rag_context_variables=["sys_instructions"]
            )
        ): response = client.chat.completions.create(
            model=model_id,
            messages=messages
        )
        
        logger.info(f"OpenAI response: {response}")

        generated_text = response.choices[0].message.content

        chat_history.append({"role": "user", "content": user_request})
        chat_history.append({"role": "assistant", "content": generated_text})
        
        metrics = {
            "input_tokens": response.usage.prompt_tokens,
            "output_tokens": response.usage.completion_tokens,
            "total_tokens": response.usage.total_tokens
        }

        return {'response': generated_text, 'sys_instructions': system_instructions, 'metrics': metrics}
    except Exception as e:
        handle_llm_error(e, user_request, "OpenAI")
    
@task(name="parse_llm_response")
def parse_llm_response(llm_response):
    try:
        logger.info(f"Parsing LLM response: {llm_response}\n")
        
        # Define the regular expression pattern to match the category and response
        pattern = r'"(?P<category>[\w-]+)":\s*"(?P<response>.+?)":\s*"(?P<reason>.+?)"'

        # Search for the pattern in the input string
        match = re.match(pattern, llm_response)

        # If a match is found, extract the values
        if match:
            category = match.group("category")
            response = match.group("response")
            reason = match.group("reason")
            
            logger.info(f"Parsed successfully: Category={category}, Response={response}, Reason={reason}\n")
            
            parsed_llm_response = {
                "category": category,
                "response": response,
                "reason": reason,
                "raw_llm_answer": llm_response
            }

            return parsed_llm_response
        else:
            # If no match, raise an error for invalid format
            raise Exception("The LLM response is not in the expected format.")
    
    except Exception as e:
        raise Exception(f"An unexpected error occurred while parsing response: {str(e)}")

@workflow(name="process_help_customer_service_request")
def process_help_cs_request(categorized_llm_answer):
    try:
        faqs = f"{get_data_set('resources/faqs.json')}"
        
        additional_sys_information = [
            """The user's request was categorized as 'Help-Customer-Service'.
            
            Before directing the user to customer service, always attempt to resolve their question using the following FAQs:
            """,
            faqs,
            "",
            """
            The FAQs dataset contains common questions and answers related to Swagstore, an e-commerce website. Each FAQ entry includes two key elements:
            
            1. Question: The customer's inquiry related to products, services, or shopping experience at Swagstore.
            2. Answer: A concise response to the customer's inquiry, providing clear information or guidance.
            
            The data is formatted as a JSON array of objects, where each object consists of a 'question' and its corresponding 'answer'. This structure is designed to be easily consumable by a chatbot or FAQ system to provide accurate and helpful information to Swagstore customers.
            
            Example structure:
            {
                "question": "How do I contact customer service?",
                "answer": "You can reach customer service at 1-800-555-1234. (Hours: 8:00 AM to 5:00 PM EST)."
            }
          
            If a user directly asks for customer service, first attempt to understand their issue by checking if it can be resolved using the FAQ. 
            For example, if the user asks, "How do I return a product?" and the FAQ has an answer about returns, use that answer first.
            
            If none of the FAQs directly answer the user's question or if further clarification is needed, only then politely guide the user to contact customer service.
            
            The customer service contact information is:
            Phone: 1-800-555-1234
            Hours: 8:00 AM to 5:00 PM EST
            
            Example of correct use of the FAQs to resolve a query:
            "Final": "We offer a 30-day return policy on most products. Items must be in their original condition and packaging. Visit our returns page for more details.":"The FAQ was used to answer the user's question."
            
            Example if escalation to customer service is needed:
            "Customer-Service": "I'm sorry, I wasn't able to resolve your request using the information available. Please contact our customer service team at 1-800-555-1234 (Hours: 8:00 AM to 5:00 PM EST).":"The FAQs did not resolve the user's request."
            
            For example, if a user asks, 'I need help finding a blue t-shirt,' categorize this as 'Need-Help.' 
            If you respond with, 'We have several blue t-shirts. Here's a link: [link],' categorize the response as 'Final' since you directly addressed their need.
            However, if you respond with, 'What shade of blue are you looking for?' the category remains 'Need-Help,' as you are still gathering information to resolve the query.
            
            Once you categorize a response as 'Final,' you can re-categorize based on the next user input.

            Ensure that each query is answered as fully as possible using available FAQs before offering customer service as a last resort.
            """
        ]

        get_latest_cs_info() # This is just to create more delay to demonstrate Datadog.

        sys_info_string = "\n".join(additional_sys_information) 

        logger.info(f"Processing Need-Help request with update sysprompt: {sys_info_string}")

        raw_llm_answer = call_llm(user_request=categorized_llm_answer['user_request'], sys_instructions=sys_info_string)

        parsed_llm_response = parse_llm_response(raw_llm_answer['response'])
        parsed_llm_response['metrics'] = raw_llm_answer['metrics'] 
        parsed_llm_response['sys_instructions'] = raw_llm_answer['sys_instructions']

        return parsed_llm_response
    except Exception as e:
        handle_llm_error(e, categorized_llm_answer['user_request'], "Help-Customer-Service")

@retrieval(name="get_latest_cs_info")
def get_latest_cs_info(path="resources/cs_info.json"):
    sleeper = random.randrange(10,30)/100
    logger.info(f"Sleeping for: {sleeper}")
    time.sleep(sleeper)
    data_set = json.load(open(path))

    LLMObs.annotate(
        output_data = [
            { "text": f"{data_set}", "name": path, "score": 1.0}
        ]
    )

    return {"hours"}

@workflow(name="process_product_information_request")
def process_product_information_request(categorized_llm_answer):
    products = f"{get_data_set(Config.PRODUCTS_JSON)}"
    
    additional_sys_information = [
        """This is additional information for handling requests in the <Product-Information> category.
        The user's request has been categorized as 'Product-Information'. Use the provided products dataset to answer the user's question, if applicable:
        """,
        products,
        "",
        """The products dataset contains the following keys: 
        - 'id': a unique string that identifies each product
        - 'name': the product name
        - 'description': a short summary of the product's features
        - 'picture': the relative URL for the product image 
        - 'priceUsd': an object with 'units' for the main dollar amount and 'nanos' for the fraction of a dollar
        - 'categories': an array of strings indicating the product categories.
        When a user asks about available products, provide the list of categories first for the user to select from.
        When displaying product information, use the following format:
        <ul><li><strong>Product Name:</strong> Product Description <br> <img src="picture_url" alt="Product Image"></li></ul> 
        Replace 'picture_url' with the actual product image URL from the dataset, ensuring it's properly formatted in HTML to display the image.
        Make sure the image URL is included in the <img> tag's 'src' attribute so that the browser can render the image correctly.
        If the user requests a picture of a product, respond with the product's information, including the image in the <img> tag format.
        For example, if a user asks, 'I want to know the price of The Dog T-shirt', categorize this as 'Product-Information'. If you respond with 'The Dog T-shirt is $29.99', categorize the response as 'Final' since you directly addressed their query. If further clarification is needed, keep the category as 'Product-Information'.
        Once you've fully answered the question using the dataset, set the category to <Final>.
        Example of a correct response: 
        "Final":"<ul><li><strong>Name:</strong> Dog Steel Bottle <br><strong>Description:</strong> NoLimit - robust stainless steel vacuum flask including sports lid. <br><img src='/static/images/steel-bottle.jpg' alt='Dog Steel Bottle'></li></ul>":"The user asked for a picture of the Dog Steel Bottle. I provided the image as requested, along with the product name and description for context.
        Ensure consistency in formatting and make sure all responses are accurate and relevant to the user's query."""
    ]

    sys_info_string = "\n".join(additional_sys_information) 

    logger.info(f"Processing Product-Information request with update sysprompt: {sys_info_string}")

    raw_llm_answer = call_llm(user_request=categorized_llm_answer['user_request'], sys_instructions=sys_info_string)
    
    parsed_llm_response = parse_llm_response(raw_llm_answer['response'])
    parsed_llm_response['metrics'] = raw_llm_answer['metrics'] 
    parsed_llm_response['sys_instructions'] = raw_llm_answer['sys_instructions']

    return parsed_llm_response

@workflow(name="process_promotion_request")
def process_promotion_request(categorized_llm_answer):
    promotions = f"{get_data_set('resources/promotions.json')}"

    additional_sys_information = [
    """This is additional information for handling requests in the <Promotion> category..
    You have access to the following promotion dataset, which contains the following attributes for each promotion:
    - id: The unique identifier for the promotion.
    - code: The discount code the customer can use during checkout.
    - description: A brief explanation of the promotion.
    - start_date: The date the promotion begins.
    - end_date: The date the promotion ends.
    - discount_percentage: The percentage discount applied by the promotion.
    - applicable_product: Specifies whether the promotion applies to a specific product or the entire store.
    - status: The current status of the promotion (e.g., 'active', 'expired').
    - minimum_purchase: The minimum purchase amount required to apply the promotion.
    - usage_limit: The maximum number of times this promotion can be used.
    Here is the dataset:
    """,
    promotions,
    "",
    """Here's how you should format the response to the customer:
    - Example for a single product promotion: 'Good news! We have a special offer on the Dog Steel Bottle. Use code <strong>STEELBOTTLE10</strong> to get <strong>10% off</strong>. No minimum purchase required. Hurry, this offer ends on <strong>December 31, 2024</strong>!'
    - Example for a storewide promotion: 'Great news! You can enjoy <strong>5% off</strong> across the entire Swagstore with code <strong>STOREWIDE5</strong>. This offer is valid until <strong>November 30, 2024</strong>, and requires a minimum purchase of <strong>$20</strong>. Don't miss out!'
    
    Ensure that:
    1. The promotion code is easy to find in the response (use bold formatting for emphasis).
    2. The discount percentage, applicable products, and key details (e.g., end date or minimum purchase) are clearly mentioned.
    3. If the promotion is ending soon, create urgency by encouraging the user to act quickly.
    4. Always present the information in a friendly, helpful, and concise tone.

    IMPORTANT:
    - If a promotion has expired, kindly inform the customer that the promotion is no longer available and guide them to any active promotions.
    - If the customer is eligible for multiple promotions, present them in a prioritized order based on the most significant discount.
    - If a promotion requires a minimum purchase, make sure to inform the customer.
    When the customer asks for information on available promotions, provide a friendly and engaging response like: 'Here are the current promotions we have available for you.'
    Make sure the customer is always satisfied with the promotion information you provide!
    """
    ]

    sys_info_string = "\n".join(additional_sys_information) 

    logger.info(f"Processing Promotion request with update sysprompt: {sys_info_string}")

    raw_llm_answer = call_llm(user_request=categorized_llm_answer['user_request'], sys_instructions=sys_info_string)
    
    parsed_llm_response = parse_llm_response(raw_llm_answer['response'])
    parsed_llm_response['metrics'] = raw_llm_answer['metrics'] 
    parsed_llm_response['sys_instructions'] = raw_llm_answer['sys_instructions']

    return parsed_llm_response

@workflow(name="process_feedback_request")
def process_feedback_request(categorized_llm_answer):
    additional_sys_information = [
        """
        This is additional information for handling requests in the <Feedback> category.
        
        Your goal is to collect user feedback and ensure it is properly recorded and summarized. Always be polite, friendly, and professional when requesting feedback.
        
        When asking for feedback, ensure that you collect both the feedback content and contact information (either a phone number or email address) so that customer service can follow up if necessary.
        
        Here's how to guide the customer when collecting feedback:
        1. Politely ask the user for feedback about their experience with Swagstore, its products, or services.
        2. After receiving the feedback, summarize it for the user in a clear and structured format.
        3. Ask the customer for confirmation of the feedback summary to ensure it is accurate.
        4. Validate that the phone number or email address provided is in the correct format (e.g. a minimum of 10 digits for the phone number and a valid email format like 'xxx@domain.XXX').

        The feedback summary should follow this clear format:
        
        <strong>Feedback Summary:</strong><br>
        <ul>
        <li><strong>Feedback:</strong> <feedback content></li>
        <li><strong>Contact Information:</strong> <contact information></li>
        </ul>
        
        
        Once the feedback content is collected and confirmed, categorize the request as 'Final.' If there are any follow-up questions or additional input from the user, you can re-categorize based on the next input.
        
        Ensure that:
        1. You accurately summarize the feedback and make sure the user confirms it.
        2. You always collect valid contact information (phone number or email) to allow for follow-up if necessary.
        3. You politely thank the customer for their feedback, making them feel valued.
        
        Example Response:
        'Thank you for your feedback! Here's what I have:<br><br><strong>Feedback Summary:</strong><br><ul><li><strong>Feedback:</strong> 'The ordering process was smooth but the delivery took longer than expected.'</li><li><strong>Contact Information:</strong> 'john.doe@example.com'</li></ul>Does this look correct?'
        
        Once confirmed, respond with a polite closing message, such as:
        'Thank you for confirming! Your feedback has been noted, and our customer service team may follow up if needed.'
        
        After confirmation, categorize the conversation as 'Final,' but always be ready to assist further if the user has more questions or requests."""
    ]   

    sys_info_string = "\n".join(additional_sys_information) 

    logger.info(f"Processing Feedback request with update sysprompt: {sys_info_string}")

    raw_llm_answer = call_llm(user_request=categorized_llm_answer['user_request'], sys_instructions=sys_info_string)
    
    parsed_llm_response = parse_llm_response(raw_llm_answer['response'])
    parsed_llm_response['metrics'] = raw_llm_answer['metrics'] 
    parsed_llm_response['sys_instructions'] = raw_llm_answer['sys_instructions']

    return parsed_llm_response

@retrieval(name="get_data_set")
def get_data_set(path:str):
    # Give me a float between 0.5 and 750 ms
    sleeper = random.randrange(10,75)/100
    logger.info(f"Sleeping for: {sleeper}")
    time.sleep(sleeper)
    data_set = json.load(open(path))

    LLMObs.annotate(
        output_data = [
            { "text": f"{data_set}", "name": path, "score": 1.0}
        ]
    )

    return data_set

@workflow(name="validate_llm_setup")
def validate_llm_setup(message):
    logger.info(f"Validating {LLM_TYPE} is setup properly.")
    LLMObs.annotate(input_data=message)
    try:
        raw_llm_answer = call_llm(message)
        response = parse_llm_response(raw_llm_answer['response'])['response']
        LLMObs.annotate(metrics=raw_llm_answer['metrics'])
        return response
    except Exception as e:
        logger.error("Exception while validating llm setup", exc_info=True)
        exit(1)

@app.route('/health')
def health_check():
    """Health check endpoint for monitoring"""
    try:
        health_status = {
            "status": "healthy",
            "version": app_version,
            "llm_type": LLM_TYPE,
            "timestamp": time.time()
        }
        
        # Check LLM connectivity
        if LLM_TYPE == "OPEN_AI":
            client.models.list()
        elif LLM_TYPE == "GEMINI":
            model = GenerativeModel(MODEL_ID)
            model.get_model()
            
        return jsonify(health_status), 200
    except Exception as e:
        logger.error(f"Health check failed: {str(e)}", exc_info=True)
        return jsonify({
            "status": "unhealthy",
            "error": str(e),
            "version": app_version,
            "timestamp": time.time()
        }), 503

# Main entry point for running the Flask app
if __name__ == '__main__':
    logger.info(f"Starting Swagbot version {app_version}")
    llm_response= validate_llm_setup(f"Are you up {LLM_TYPE}?")
    app.secret_key = 'very_secret_pass'
    app.run(
        host=os.environ.get("FLASK_HOST", "127.0.0.1"),
        debug=True,
        port=int(os.environ.get("FLASK_PORT", 3000)),
    )